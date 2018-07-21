defmodule Hedwig.Adapters.Slack do
  use Hedwig.Adapter

  require Logger

  alias HedwigSlack.{Connection, RTM, HTTP}

  defmodule State do 
    defstruct conn: nil,
              conn_ref: nil,
              channels: %{},
              groups: %{},
              team_id: nil,
              id: nil,
              name: nil,
              opts: nil,
              robot: nil,
              token: nil,
              users: %{}
  end

  def init({robot, opts}) do
    {token, opts} = Keyword.pop(opts, :token)
    Kernel.send(self(), :rtm_start)
    {:ok, %State{opts: opts, robot: robot, token: token}}
  end

  def handle_cast({:send, msg}, state) do
    slack_message(msg)
    |> dispatch(state)

    {:noreply, state}
  end

  def handle_cast({:reply, %{user: user, text: text} = msg}, state) do
      msg
      |> Map.merge(%{ text: "<@#{user.id}|#{user.name}>: #{text}"})
      |> slack_message()
      |> dispatch(state)

    {:noreply, state}
  end

  def handle_cast({:emote, %{text: _text} = msg}, state) do
    msg
    |> Map.merge(%{subtype: "me_message"})
    |> slack_message()
    |> dispatch(state)

    {:noreply, state}
  end

  def handle_info(:rtm_start, %{token: token} = state) do
    case RTM.start(token) do
      {:ok, %{body: data}} ->
        handle_rtm_data(data)
        {:ok, conn, ref} = Connection.start(data["url"])
        {:noreply, %State{state | conn: conn, conn_ref: ref}}
      {:error, _} = error ->
        handle_network_failure(error, state)
    end
  end

  # Ignore all messages from the bot.
  def handle_info(%{"user" => user}, %{id: user} = state) do
    {:noreply, state}
  end

  def handle_info(%{"subtype" => "channel_join", "channel" => channel, "user" => user}, state) do
    channels = put_channel_user(state.channels, channel, user)
    {:noreply, %{state | channels: channels}}
  end

  def handle_info(%{"subtype" => "channel_leave", "channel" => channel, "user" => user}, state) do
    channels = delete_channel_user(state.channels, channel, user)
    {:noreply, %{state | channels: channels}}
  end

  def handle_info(%{"type" => "message", "user" => user} = msg, %{robot: robot, users: users} = state) do
    msg = %Hedwig.Message{
      ref: make_ref(),
      robot: robot,
      room: msg["channel"],
      text: msg["text"],
      type: "message",
      private: msg,
      user: %Hedwig.User{
        id: user,
        name: users[user]["name"]
      }
    }

    if msg.text do
      :ok = Hedwig.Robot.handle_in(robot, msg)
    end

    {:noreply, state}
  end

  def handle_info({:channels, channels}, state) do
    {:noreply, %{state | channels: reduce(channels, state.channels)}}
  end

  def handle_info({:groups, groups}, state) do
    {:noreply, %{state | groups: reduce(groups, state.groups)}}
  end

  def handle_info({:self, %{"id" => id, "name" => name}}, state) do
     {:noreply, %{state | id: id, name: name}}
  end

  def handle_info({:users, users}, state) do
    {:noreply, %{state | users: reduce(users, state.users)}}
  end

  def handle_info({:team, team}, state) do
    {:noreply, %{state | team_id: team["id"] }}
  end

  def handle_info(%{"type" => "team_join", "user" => user}, state) do
    {:noreply, %{state | users: reduce([user], state.users)}}
  end

  def handle_info(%{"presence" => presence, "type" => "presence_change", "user" => user}, state) do
    users = update_in(state.users, [user], &Map.put(&1, "presence", presence))
    {:noreply, %{state | users: users}}
  end

  def handle_info(%{"type" => "reconnect_url"}, state), do:
    {:noreply, state}

  def handle_info(%{"type" => "hello"}, %{robot: robot} = state) do
    Hedwig.Robot.handle_connect(robot)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{conn: pid, conn_ref: ref} = state) do
    handle_network_failure(reason, state)
  end

  def handle_info(msg, %{robot: robot} = state) do
    Hedwig.Robot.handle_in(robot, msg)
    {:noreply, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  defp handle_network_failure(reason, %{robot: robot} = state) do
    case Hedwig.Robot.handle_disconnect(robot, reason) do
      {:disconnect, reason} ->
        {:stop, reason, state}
      {:reconnect, timeout} ->
        Process.send_after(self(), :rtm_start, timeout)
        {:noreply, reset_state(state)}
      :reconnect ->
        Kernel.send(self(), :rtm_start)
        {:noreply, reset_state(state)}
    end
  end

  defp slack_message(%Hedwig.Message{} = msg, overrides \\ %{}) do
    attachments = Map.get(msg, :private, %{}) |> Map.get("attachments", [])
    msg = Map.merge(%{
      channel: msg.room, 
      text: msg.text, 
      type: msg.type, 
      thread_ts: Map.get(msg, :thread_ts),
      reply_broadcast: Map.get(msg, :reply_broadcast, false),
      attachments: attachments
    }, overrides)

    case attachments do
      [] ->
        {:rtm, msg }
      _ ->
        {:http, msg }
    end
  end

  defp dispatch({:http, msg}, state) do
    HTTP.post("/chat.postMessage", [ 
      body: Map.merge(msg, %{as_user: true}),
      headers: [
        {"Content-Type", "application/json; charset=utf-8"},
        {"Authorization", "Bearer #{state.token}"}
      ]
    ])
  end

  defp dispatch({:rtm, msg }, state) do
    Connection.ws_send(state.conn, msg)
  end

  defp put_channel_user(channels, channel_id, user_id) do
    update_in(channels, [channel_id, "members"], &([user_id | &1]))
  end

  defp delete_channel_user(channels, channel_id, user_id) do
    update_in(channels, [channel_id, "members"], &(&1 -- [user_id]))
  end

  defp reduce(collection, acc) do
    Enum.reduce(collection, acc, fn item, acc ->
      Map.put(acc, item["id"], item)
    end)
  end

  defp reset_state(state) do
    %{state | conn: nil,
              conn_ref: nil,
              channels: %{},
              groups: %{},
              id: nil,
              name: nil,
              users: %{}}
  end

  defp handle_rtm_data(data) do
    Kernel.send(self(), {:team, data["team"]})
    Kernel.send(self(), {:channels, data["channels"]})
    Kernel.send(self(), {:groups, data["groups"]})
    Kernel.send(self(), {:self, data["self"]})
    Kernel.send(self(), {:users, data["users"]})
  end
end
