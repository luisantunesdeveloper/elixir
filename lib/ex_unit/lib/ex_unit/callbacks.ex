defmodule ExUnit.Callbacks do
  @moduledoc ~S"""
  Defines ExUnit callbacks.

  This module defines both `setup_all` and `setup` callbacks, as well as
  the `on_exit/2` function.

  The setup callbacks are defined via macros and each one can optionally
  receive a map with metadata, usually referred to as `context`. The
  callback may optionally put extra data into the `context` to be used in
  the tests.

  The `setup_all` callbacks are invoked only once to setup the test case before any
  test is run and all `setup` callbacks are run before each test. No callback
  runs if the test case has no tests or all tests have been filtered out.

  `on_exit/2` callbacks are registered on demand, usually to undo an action
  performed by a setup callback. `on_exit/2` may also take a reference,
  allowing callback to be overridden in the future. A registered `on_exit/2`
  callback always runs, while failures in `setup` and `setup_all` will stop
  all remaining setup callbacks from executing.

  Finally, `setup_all` callbacks run in the test case process, while all
  `setup` callbacks run in the same process as the test itself. `on_exit/2`
  callbacks always run in a separate process than the test case or the
  test itself. Since the test process exits with reason `:shutdown`, most
  of times `on_exit/2` can be avoided as processes are going to clean
  up on their own.

  ## Context

  If you return a keyword list, a map, or `{:ok, keywords | map}` from
  `setup_all`, the keyword list/map will be merged into the current context and
  be available in all subsequent `setup_all`, `setup`, and the test itself.

  Similarly, returning a keyword list, map, or `{:ok, keywords | map}` from
  `setup` means that the returned keyword list/map will be merged into the
  current context and be available in all subsequent `setup` and the `test`
  itself.

  Returning `:ok` leaves the context unchanged (both in `setup` and `setup_all`
  callbacks).

  Returning anything else from `setup_all` will force all tests to fail,
  while a bad response from `setup` causes the current test to fail.

  ## Examples

      defmodule AssertionTest do
        use ExUnit.Case, async: true

        # "setup_all" is called once to setup the case before any test is run
        setup_all do
          IO.puts "Starting AssertionTest"

          # No context is returned here
          :ok
        end

        # "setup" is called before each test is run
        setup do
          IO.puts "This is a setup callback"

          on_exit fn ->
            IO.puts "This is invoked once the test is done"
          end

          # Returns extra metadata to be merged into context
          [hello: "world"]
        end

        # Same as "setup", but receives the context
        # for the current test
        setup context do
          IO.puts "Setting up: #{context[:test]}"
          :ok
        end

        # Setups can also invoke a local or imported function that can return a context
        setup :invoke_local_or_imported_function

        test "always pass" do
          assert true
        end

        test "another one", context do
          assert context[:hello] == "world"
        end

        defp invoke_local_or_imported_function(context) do
          [from_named_setup: true]
        end
      end

  """

  @doc false
  defmacro __using__(_) do
    quote do
      @ex_unit_describe nil
      @ex_unit_setup []
      @ex_unit_setup_all []

      @before_compile unquote(__MODULE__)
      import unquote(__MODULE__)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    [compile_callbacks(env, :setup),
     compile_callbacks(env, :setup_all)]
  end

  @doc """
  Defines a callback to be run before each test in a case.

  ## Examples

      setup :clean_up_tmp_directory

  """
  defmacro setup(block) do
    if Keyword.keyword?(block) do
      do_setup(quote(do: _), block)
    else
      quote do
        @ex_unit_setup ExUnit.Callbacks.__callback__(unquote(block), @ex_unit_describe) ++
                       @ex_unit_setup
      end
    end
  end

  @doc """
  Defines a callback to be run before each test in a case.

  ## Examples

      setup context do
        [conn: Plug.Conn.build_conn()]
      end

  """
  defmacro setup(var, block) do
    do_setup(var, block)
  end

  defp do_setup(var, block) do
    quote bind_quoted: [var: escape(var), block: escape(block)] do
      name = :"__ex_unit_setup_#{length(@ex_unit_setup)}"
      defp unquote(name)(unquote(var)), unquote(block)
      @ex_unit_setup [{name, @ex_unit_describe} | @ex_unit_setup]
    end
  end

  @doc """
  Defines a callback to be run before all tests in a case.

  ## Examples

      setup_all :clean_up_tmp_directory

  """
  defmacro setup_all(block) do
    if Keyword.keyword?(block) do
      do_setup_all(quote(do: _), block)
    else
      quote do
        @ex_unit_describe && raise "cannot invoke setup_all/1 inside describe as setup_all/1 " <>
                                   "always applies to all tests in a module"
        @ex_unit_setup_all ExUnit.Callbacks.__callback__(unquote(block), nil) ++
                           @ex_unit_setup_all
      end
    end
  end

  @doc """
  Defines a callback to be run before all tests in a case.

  ## Examples

      setup_all context do
        [conn: Plug.Conn.build_conn()]
      end

  """
  defmacro setup_all(var, block) do
    do_setup_all(var, block)
  end

  defp do_setup_all(var, block) do
    quote bind_quoted: [var: escape(var), block: escape(block)] do
      @ex_unit_describe && raise "cannot invoke setup_all/2 inside describe"
      name = :"__ex_unit_setup_all_#{length(@ex_unit_setup_all)}"
      defp unquote(name)(unquote(var)), unquote(block)
      @ex_unit_setup_all [{name, nil} | @ex_unit_setup_all]
    end
  end

  @doc """
  Defines a callback that runs on the test (or test case) exit.

  `callback` is a function that receives no arguments and
  runs in a separate process than the caller.

  `on_exit/2` is usually called from `setup` and `setup_all` callbacks,
  often to undo the action performed during `setup`. However, `on_exit/2`
  may also be called dynamically, where a reference can be used to
  guarantee the callback will be invoked only once.
  """
  @spec on_exit(term, (() -> term)) :: :ok | no_return
  def on_exit(name_or_ref \\ make_ref(), callback) when is_function(callback, 0) do
    case ExUnit.OnExitHandler.add(self(), name_or_ref, callback) do
      :ok -> :ok
      :error ->
        raise ArgumentError, "on_exit/2 callback can only be invoked from the test process"
    end
  end

  ## Helpers

  @reserved [:case, :file, :line, :test, :async, :registered, :describe]

  @doc false
  def __callback__(callback, describe) do
    for k <- List.wrap(callback) do
      if not is_atom(k) do
        raise ArgumentError, "setup/setup_all expect a callback name as an atom or " <>
                             "a list of callback names, got: #{inspect k}"
      end

      {k, describe}
    end |> Enum.reverse()
  end

  @doc false
  def __merge__(_mod, context, :ok) do
    context
  end

  def __merge__(mod, context, {:ok, value}) do
    __merge__(mod, context, value)
  end

  def __merge__(mod, _context, %{__struct__: _} = return_value) do
    raise_merge_failed!(mod, return_value)
  end

  def __merge__(mod, context, data) when is_list(data) do
    __merge__(mod, context, Map.new(data))
  end

  def __merge__(mod, context, data) when is_map(data) do
    context_merge(mod, context, data)
  end

  def __merge__(mod, _, return_value) do
    raise_merge_failed!(mod, return_value)
  end

  defp context_merge(mod, context, data) do
    Map.merge(context, data, fn
      k, v1, v2 when k in @reserved ->
        if v1 == v2, do: v1, else: raise_merge_reserved!(mod, k, v1)
      _, _, v ->
        v
    end)
  end

  defp raise_merge_failed!(mod, return_value) do
    raise "expected ExUnit callback in #{inspect mod} to return :ok | keyword | map, " <>
          "got #{inspect return_value} instead"
  end

  defp raise_merge_reserved!(mod, key, value) do
    raise "ExUnit callback in #{inspect mod} is trying to set " <>
          "reserved field #{inspect key} to #{inspect value}"
  end

  defp escape(contents) do
    Macro.escape(contents, unquote: true)
  end

  defp compile_callbacks(env, kind) do
    callbacks = Module.get_attribute(env.module, :"ex_unit_#{kind}") |> Enum.reverse

    acc =
      case callbacks do
        [] ->
          quote do: context
        [h | t] ->
          Enum.reduce t, compile_merge(h), fn callback_describe, acc ->
            quote do
              context = unquote(acc)
              unquote(compile_merge(callback_describe))
            end
          end
      end

    quote do
      def __ex_unit__(unquote(kind), context) do
        describe = Map.get(context, :describe, nil)
        unquote(acc)
      end
    end
  end

  defp compile_merge({callback, nil}) do
    quote do
      unquote(__MODULE__).__merge__(__MODULE__, context, unquote(callback)(context))
    end
  end

  defp compile_merge({callback, describe}) do
    quote do
      if unquote(describe) == describe do
        unquote(compile_merge({callback, nil}))
      else
        context
      end
    end
  end
end
