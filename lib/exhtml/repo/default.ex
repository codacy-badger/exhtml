defmodule Exhtml.Repo.Default do
  @type slug :: Exhtml.slug()
  @type server :: GenServer.server()

  @moduledoc """
  This is the default Repo implementation with mnesia database.

  ## Examples:

      iex> {:ok, pid} = Exhtml.Repo.Default.start_link []
      ...> Exhtml.Repo.Default.set(pid, :foo, :bar)
      :ok
      ...> Exhtml.Repo.Default.get(pid, :foo)
      :bar

  """

  @table_name_in_db :exhtml_contents

  use GenServer
  import Logger

  # APIs

  @doc """
  Starts a Exhtml.Repo.Default process.

  * `opts` - options for starting the process:
      * `data_dir` indicates which path the data will be persited in.
      * `data_nodes` indicates which nodes will hold persisted data. Other nodes
          will only hold data in memories.

  Returns `{:ok, pid}` if succeed, `{:error, reason}` otherwise.
  """
  @spec start_link(key: any) :: {:ok, pid} | {:error, any}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Gets content of the slug from the store.

  * `server` - PID or name of the server
  * `slug` - key of the content
  """
  @spec get(server, slug) :: any
  def get(server, slug) do
    GenServer.call(server, {:get, slug})
  end

  @doc """
  Gets content of the slug from the store since the time.

  * `server` - PID or name of the server
  * `slug` - key of the content
  * `since` - modiefied time
  """
  @spec get_since(server, slug, DateTime.t()) :: any
  def get_since(server, slug, since) do
    GenServer.call(server, {:get_since, slug, since})
  end

  @doc """
  Sets content of the slug into the store.

  * `server` - PID or name of the server
  * `slug` - key of the content
  * `content` - the content for the slug

  ## Examples:

      iex> {:ok, pid} = Exhtml.Repo.Default.start_link []
      ...> Exhtml.Repo.Default.set(pid, :foo, :bar)
      :ok
      iex> Exhtml.Repo.Default.get(pid, :foo)
      :bar
      
  """
  @spec set(server, slug, any) :: :ok
  def set(server, slug, content) do
    GenServer.call(server, {:set, slug, content})
  end

  @doc """
  Removes content of the slug from the store.

  * `server` - PID or name of the server
  * `slug` - key of the content
  """
  @spec rm(server, slug) :: :ok
  def rm(server, slug) do
    GenServer.call(server, {:rm, slug})
  end

  # Callbacks

  @doc false
  def init(opts) do
    start_db(
      opts[:data_dir] || "./exhtml_contents",
      opts[:data_nodes] || [Node.self()]
    )

    {:ok, %{}}
  end

  defp start_db(data_dir, nodes) do
    File.mkdir_p(data_dir)

    :mnesia |> :application.load()
    :mnesia |> :application.set_env(:dir, to_charlist(data_dir))
    :mnesia |> :application.set_env(:auto_repair, true)

    :mnesia.create_schema(nodes)
    :mnesia.start()
    :mnesia.create_table(@table_name_in_db, attributes: [:slug, :content], disc_copies: nodes)

    ret = :mnesia.wait_for_tables([@table_name_in_db], 5000)

    case ret do
      {:timeout, _} ->
        error("Error starting exhtml databse, timeout.")

      {:error, reason} ->
        error("Error starting exhtml databse, #{inspect(reason)}.")

      _ ->
        nil
    end

    ret
  end

  def handle_call({:get, slug}, _from, state) do
    ret =
      slug
      |> db_result
      |> db_to_val

    {:reply, ret, state}
  end

  def handle_call({:get_since, slug, since}, _from, state) do
    val =
      slug
      |> db_result
      |> db_to_val_with_time

    ret =
      case val do
        nil -> nil
        {nil, nil} -> nil
        {content, nil} -> {:ok, content}
        {content, t} -> to_content_since(content, t, since)
        _ -> {:ok, val}
      end

    {:reply, ret, state}
  end

  def handle_call({:set, slug, content}, _from, state) do
    {:atomic, _} =
      :mnesia.transaction(fn ->
        :mnesia.write(
          @table_name_in_db,
          {@table_name_in_db, slug, {content, DateTime.utc_now()}},
          :write
        )
      end)

    {:reply, :ok, state}
  end

  def handle_call({:rm, slug}, _from, state) do
    {:atomic, _} =
      :mnesia.transaction(fn ->
        :mnesia.delete(@table_name_in_db, slug, :write)
      end)

    {:reply, :ok, state}
  end

  defp db_result(slug) do
    @table_name_in_db |> :mnesia.dirty_read(slug) |> List.first()
  end

  defp db_to_val(nil), do: nil
  defp db_to_val({@table_name_in_db, _slug, {content, _t}}), do: content
  defp db_to_val({@table_name_in_db, _slug, content}), do: content

  defp db_to_val_with_time(nil), do: nil
  defp db_to_val_with_time({@table_name_in_db, _slug, {content, mtime}}), do: {content, mtime}
  defp db_to_val_with_time({@table_name_in_db, _slug, content}), do: {content, nil}

  defp to_content_since(content, _, nil), do: {:ok, content}

  defp to_content_since(content, t, since) do
    case DateTime.compare(t, since) do
      :lt -> :unchanged
      _ -> {:ok, content}
    end
  end
end
