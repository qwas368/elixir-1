defmodule Kernel.Typespec do
  @moduledoc false

  ## Deprecated API moved to Code.

  # TODO: Remove on 2.0 and move this module to Module.Typespec.

  @doc false
  def spec_to_ast(name, spec) do
    IO.warn(
      "Kernel.Typespec.spec_to_ast/2 is deprecated, please use Code.Typespec.spec_to_quoted/2 instead"
    )

    Code.Typespec.spec_to_quoted(name, spec)
  end

  @doc false
  def type_to_ast(type) do
    IO.warn(
      "Kernel.Typespec.type_to_ast/1 is deprecated, please use Code.Typespec.type_to_quoted/1 instead"
    )

    Code.Typespec.type_to_quoted(type)
  end

  @doc false
  def beam_typedocs(module) when is_atom(module) or is_binary(module) do
    IO.warn("Kernel.Typespec.beam_typedocs/1 is deprecated, please use Code.get_docs/2 instead")

    if docs = Code.get_docs(module, :type_docs) do
      for {tuple, _, _, doc} <- docs, do: {tuple, doc}
    end
  end

  @doc false
  def beam_types(module) when is_atom(module) or is_binary(module) do
    IO.warn(
      "Kernel.Typespec.beam_types/1 is deprecated, please use Code.Typespec.fetch_types/1 instead"
    )

    case Code.Typespec.fetch_types(module) do
      {:ok, types} -> types
      :error -> nil
    end
  end

  @doc false
  def beam_specs(module) when is_atom(module) or is_binary(module) do
    IO.warn(
      "Kernel.Typespec.beam_specs/1 is deprecated, please use Code.Typespec.fetch_specs/1 instead"
    )

    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} -> specs
      :error -> nil
    end
  end

  @doc false
  def beam_callbacks(module) when is_atom(module) or is_binary(module) do
    IO.warn(
      "Kernel.Typespec.beam_callbacks/1 is deprecated, please use Code.Typespec.fetch_callbacks/1 instead"
    )

    case Code.Typespec.fetch_callbacks(module) do
      {:ok, callbacks} -> callbacks
      :error -> nil
    end
  end

  ## Query helpers

  # TODO: Improve performance of the defined queries below and remove
  # the need for spec_to_signature and type_to_signature publically.

  @doc """
  Returns `true` if the current module defines a given type
  (private, opaque or not). This function is only available
  for modules being compiled.
  """
  @spec defines_type?(module, atom, arity) :: boolean
  def defines_type?(module, name, arity)
      when is_atom(module) and is_atom(name) and arity in 0..255 do
    finder = fn {_kind, expr, _caller} ->
      type_to_signature(expr) == {name, arity}
    end

    :lists.any(finder, Module.get_attribute(module, :type)) or
      :lists.any(finder, Module.get_attribute(module, :opaque))
  end

  @doc """
  Returns `true` if the current module defines a given spec.
  This function is only available for modules being compiled.
  """
  @spec defines_spec?(module, atom, arity) :: boolean
  def defines_spec?(module, name, arity)
      when is_atom(module) and is_atom(name) and arity in 0..255 do
    Enum.any?(Module.get_attribute(module, :spec), fn {_kind, expr, _caller} ->
      spec_to_signature(expr) == {name, arity}
    end)
  end

  @doc """
  Returns `true` if the current module defines a callback.
  This function is only available for modules being compiled.
  """
  @spec defines_callback?(module, atom, arity) :: boolean
  def defines_callback?(module, name, arity)
      when is_atom(module) and is_atom(name) and arity in 0..255 do
    Enum.any?(Module.get_attribute(module, :callback), fn {_kind, expr, _caller} ->
      spec_to_signature(expr) == {name, arity}
    end)
  end

  @doc false
  def spec_to_signature({:when, _, [spec, _]}), do: type_to_signature(spec)
  def spec_to_signature(other), do: type_to_signature(other)

  @doc false
  def type_to_signature({:::, _, [{name, _, context}, _]})
      when is_atom(name) and is_atom(context),
      do: {name, 0}

  def type_to_signature({:::, _, [{name, _, args}, _]}) when is_atom(name),
    do: {name, length(args)}

  def type_to_signature(_), do: :error

  ## Typespec definition and storage

  @doc """
  Defines a typespec.

  Invoked by `Kernel.@/1` expansion.
  """
  def deftypespec(:spec, expr, _line, _file, module, pos) do
    Module.store_typespec(module, :spec, {:spec, expr, pos})
  end

  def deftypespec(kind, expr, line, file, module, pos) when kind in [:type, :typep, :opaque] do
    case type_to_signature(expr) do
      {name, arity} -> store_typedoc(line, file, module, kind, name, arity)
      :error -> :error
    end

    Module.store_typespec(module, kind, {kind, expr, pos})
  end

  def deftypespec(kind, expr, line, file, module, pos) when kind in [:callback, :macrocallback] do
    case spec_to_signature(expr) do
      {name, arity} ->
        store_callbackdoc(line, file, module, kind, name, arity)

      :error ->
        :error
    end

    Module.store_typespec(module, kind, {kind, expr, pos})
  end

  defp store_callbackdoc(line, _file, module, kind, name, arity) do
    table = :elixir_module.data_table(module)
    {line, doc} = get_doc_info(table, :doc, line)
    _ = get_since_info(table)
    :ets.insert(table, {{:callbackdoc, {name, arity}}, line, kind, doc})
  end

  defp get_doc_info(table, attr, line) do
    case :ets.take(table, attr) do
      [{^attr, {line, doc}, _, _}] -> {line, doc}
      [] -> {line, nil}
    end
  end

  defp get_since_info(table) do
    :ets.take(table, :since)
  end

  defp store_typedoc(line, file, module, kind, name, arity) do
    table = :elixir_module.data_table(module)
    {line, doc} = get_doc_info(table, :typedoc, line)
    _ = get_since_info(table)

    if kind == :typep && doc do
      warning =
        "type #{name}/#{arity} is private, @typedoc's are always discarded for private types"

      :elixir_errors.warn(line, file, warning)
    end

    :ets.insert(table, {{:typedoc, {name, arity}}, line, kind, doc})
  end

  ## Translation from Elixir AST to typespec AST

  @doc false
  def translate_typespecs_for_module(table) do
    translate_type = fn {kind, expr, caller} -> translate_type(kind, expr, caller) end
    translate_spec = fn {kind, expr, caller} -> translate_spec(kind, expr, caller) end

    types = take_spec(table, :type) ++ take_spec(table, :typep) ++ take_spec(table, :opaque)
    types = Enum.map(types, translate_type)

    specs = Enum.map(take_spec(table, :spec), translate_spec)
    callbacks = Enum.map(take_spec(table, :callback), translate_spec)
    macrocallbacks = Enum.map(take_spec(table, :macrocallback), translate_spec)
    optional_callbacks = List.flatten(take_spec(table, :optional_callbacks))

    {types, specs, callbacks, macrocallbacks, optional_callbacks}
  end

  defp take_spec(table, key) do
    case :ets.take(table, key) do
      [{^key, value, _, _}] -> value
      [] -> []
    end
  end

  defp translate_type(kind, {:::, _, [{name, _, args}, definition]}, pos)
       when is_atom(name) and name != ::: do
    caller = :elixir_locals.get_cached_env(pos)

    args =
      if is_atom(args) do
        []
      else
        for(arg <- args, do: variable(arg))
      end

    vars = for {:var, _, var} <- args, do: var
    spec = typespec(definition, vars, caller)
    vars = for {:var, _, _} = var <- args, do: var
    type = {name, spec, vars}
    arity = length(vars)

    {kind, export} =
      case kind do
        :type -> {:type, true}
        :typep -> {:type, false}
        :opaque -> {:opaque, true}
      end

    if builtin_type?(name, arity) do
      compile_error(caller, "type #{name}/#{arity} is a builtin type and it cannot be redefined")
    end

    {kind, {name, arity}, caller.line, type, export}
  end

  defp translate_type(_kind, other, pos) do
    caller = :elixir_locals.get_cached_env(pos)
    type_spec = Macro.to_string(other)
    compile_error(caller, "invalid type specification: #{type_spec}")
  end

  defp translate_spec(kind, {:when, _meta, [spec, guard]}, pos) do
    caller = :elixir_locals.get_cached_env(pos)
    translate_spec(kind, spec, guard, caller)
  end

  defp translate_spec(kind, spec, pos) do
    caller = :elixir_locals.get_cached_env(pos)
    translate_spec(kind, spec, [], caller)
  end

  defp translate_spec(kind, {:::, meta, [{name, _, args}, return]}, guard, caller)
       when is_atom(name) and name != ::: do
    translate_spec(kind, meta, name, args, return, guard, caller)
  end

  defp translate_spec(_kind, {name, _meta, _args} = spec, _guard, caller)
       when is_atom(name) and name != ::: do
    spec = Macro.to_string(spec)
    compile_error(caller, "type specification missing return type: #{spec}")
  end

  defp translate_spec(_kind, spec, _guard, caller) do
    spec = Macro.to_string(spec)
    compile_error(caller, "invalid type specification: #{spec}")
  end

  defp translate_spec(kind, meta, name, args, return, guard, caller) when is_atom(args),
    do: translate_spec(kind, meta, name, [], return, guard, caller)

  defp translate_spec(kind, meta, name, args, return, guard, caller) do
    ensure_no_defaults!(args)

    unless Keyword.keyword?(guard) do
      error = "expected keywords as guard in type specification, got: #{Macro.to_string(guard)}"
      compile_error(caller, error)
    end

    vars = Keyword.keys(guard)
    spec = {:type, line(meta), :fun, fn_args(meta, args, return, vars, caller)}

    spec =
      case guard_to_constraints(guard, vars, meta, caller) do
        [] -> spec
        constraints -> {:type, line(meta), :bounded_fun, [spec, constraints]}
      end

    arity = length(args)
    {kind, {name, arity}, caller.line, spec}
  end

  # TODO: Remove char_list type by 2.0
  defp builtin_type?(:char_list, 0), do: true
  defp builtin_type?(:charlist, 0), do: true
  defp builtin_type?(:as_boolean, 1), do: true
  defp builtin_type?(:struct, 0), do: true
  defp builtin_type?(:nonempty_charlist, 0), do: true
  defp builtin_type?(:keyword, 0), do: true
  defp builtin_type?(:keyword, 1), do: true
  defp builtin_type?(name, arity), do: :erl_internal.is_type(name, arity)

  defp ensure_no_defaults!(args) do
    Enum.each(args, fn
      {:::, _, [left, right]} ->
        ensure_not_default(left)
        ensure_not_default(right)
        left

      other ->
        ensure_not_default(other)
        other
    end)
  end

  defp ensure_not_default({:\\, _, [_, _]}) do
    raise ArgumentError, "default arguments \\\\ not supported in typespecs"
  end

  defp ensure_not_default(_), do: :ok

  defp guard_to_constraints(guard, vars, meta, caller) do
    line = line(meta)

    Enum.flat_map(guard, fn
      {_name, {:var, _, context}} when is_atom(context) ->
        []

      {name, type} ->
        constraint = [
          {:atom, line, :is_subtype},
          [{:var, line, name}, typespec(type, vars, caller)]
        ]

        [{:type, line, :constraint, constraint}]
    end)
  end

  ## To typespec conversion

  defp line(meta) do
    Keyword.get(meta, :line, 0)
  end

  # Handle unions
  defp typespec({:|, meta, [_, _]} = exprs, vars, caller) do
    exprs = collect_union(exprs)
    union = for e <- exprs, do: typespec(e, vars, caller)
    {:type, line(meta), :union, union}
  end

  # Handle binaries
  defp typespec({:<<>>, meta, []}, _, _) do
    {:type, line(meta), :binary, [{:integer, line(meta), 0}, {:integer, line(meta), 0}]}
  end

  defp typespec(
         {:<<>>, meta, [{:::, unit_meta, [{:_, _, ctx1}, {:*, _, [{:_, _, ctx2}, unit]}]}]},
         _,
         _
       )
       when is_atom(ctx1) and is_atom(ctx2) and is_integer(unit) do
    {:type, line(meta), :binary, [{:integer, line(meta), 0}, {:integer, line(unit_meta), unit}]}
  end

  defp typespec({:<<>>, meta, [{:::, size_meta, [{:_, _, ctx}, size]}]}, _, _)
       when is_atom(ctx) and is_integer(size) do
    {:type, line(meta), :binary, [{:integer, line(size_meta), size}, {:integer, line(meta), 0}]}
  end

  defp typespec(
         {
           :<<>>,
           meta,
           [
             {:::, size_meta, [{:_, _, ctx1}, size]},
             {:::, unit_meta, [{:_, _, ctx2}, {:*, _, [{:_, _, ctx3}, unit]}]}
           ]
         },
         _,
         _
       )
       when is_atom(ctx1) and is_atom(ctx2) and is_atom(ctx3) and is_integer(size) and
              is_integer(unit) do
    args = [{:integer, line(size_meta), size}, {:integer, line(unit_meta), unit}]
    {:type, line(meta), :binary, args}
  end

  ## Handle maps and structs
  defp typespec({:map, meta, args}, _vars, _caller) when args == [] or is_atom(args) do
    {:type, line(meta), :map, :any}
  end

  defp typespec({:%{}, meta, fields} = map, vars, caller) do
    fields =
      Enum.map(fields, fn
        {k, v} when is_atom(k) ->
          args = [typespec(k, vars, caller), typespec(v, vars, caller)]
          {:type, line(meta), :map_field_exact, args}

        {{:required, meta2, [k]}, v} ->
          args = [typespec(k, vars, caller), typespec(v, vars, caller)]
          {:type, line(meta2), :map_field_exact, args}

        {{:optional, meta2, [k]}, v} ->
          args = [typespec(k, vars, caller), typespec(v, vars, caller)]
          {:type, line(meta2), :map_field_assoc, args}

        {k, v} ->
          # TODO: Warn on Elixir v1.8 (since v1.6 is the first version to drop support for 18 and
          # older)
          # warning =
          #   "invalid map specification. %{foo => bar} is deprecated in favor of " <>
          #   "%{required(foo) => bar} and %{optional(foo) => bar}."
          # :elixir_errors.warn(caller.line, caller.file, warning)
          args = [typespec(k, vars, caller), typespec(v, vars, caller)]
          {:type, line(meta), :map_field_assoc, args}

        {:|, _, [_, _]} ->
          error =
            "invalid map specification. When using the | operator in the map key, " <>
              "make sure to wrap the key type in parentheses: #{Macro.to_string(map)}"

          compile_error(caller, error)

        _ ->
          compile_error(caller, "invalid map specification: #{Macro.to_string(map)}")
      end)

    {:type, line(meta), :map, fields}
  end

  defp typespec({:%, _, [name, {:%{}, meta, fields}]}, vars, caller) do
    # We cannot set a function name to avoid tracking
    # as a compile time dependency, because for structs it actually is one.
    module = Macro.expand(name, caller)

    struct =
      if module == caller.module do
        Module.get_attribute(module, :struct) ||
          compile_error(caller, "struct is not defined for #{Macro.to_string(name)}")
      else
        module.__struct__
      end

    struct = struct |> Map.from_struct() |> Map.to_list()

    unless Keyword.keyword?(fields) do
      compile_error(caller, "expected key-value pairs in struct #{Macro.to_string(name)}")
    end

    types =
      Enum.map(struct, fn {field, _} ->
        {field, Keyword.get(fields, field, quote(do: term()))}
      end)

    Enum.each(fields, fn {field, _} ->
      unless Keyword.has_key?(struct, field) do
        compile_error(caller, "undefined field #{field} on struct #{Macro.to_string(name)}")
      end
    end)

    typespec({:%{}, meta, [__struct__: module] ++ types}, vars, caller)
  end

  # Handle records
  defp typespec({:record, meta, [atom]}, vars, caller) do
    typespec({:record, meta, [atom, []]}, vars, caller)
  end

  defp typespec({:record, meta, [atom, fields]}, vars, caller) do
    # We cannot set a function name to avoid tracking
    # as a compile time dependency because for records it actually is one.
    case Macro.expand({atom, [], [{atom, [], []}]}, caller) do
      keyword when is_list(keyword) ->
        types =
          Enum.map(keyword, fn {field, _} ->
            Keyword.get(fields, field, quote(do: term()))
          end)

        Enum.each(fields, fn {field, _} ->
          unless Keyword.has_key?(keyword, field) do
            compile_error(caller, "undefined field #{field} on record #{inspect(atom)}")
          end
        end)

        typespec({:{}, meta, [atom | types]}, vars, caller)

      _ ->
        compile_error(caller, "unknown record #{inspect(atom)}")
    end
  end

  # Handle ranges
  defp typespec({:.., meta, args}, vars, caller) do
    args = for arg <- args, do: typespec(arg, vars, caller)
    {:type, line(meta), :range, args}
  end

  # Handle special forms
  defp typespec({:__MODULE__, _, atom}, vars, caller) when is_atom(atom) do
    typespec(caller.module, vars, caller)
  end

  defp typespec({:__aliases__, _, _} = alias, vars, caller) do
    # We set a function name to avoid tracking
    # aliases in typespecs as compile time dependencies.
    atom = Macro.expand(alias, %{caller | function: {:typespec, 0}})
    typespec(atom, vars, caller)
  end

  # Handle funs
  defp typespec([{:->, meta, [arguments, return]}], vars, caller) when is_list(arguments) do
    args = fn_args(meta, arguments, return, vars, caller)
    {:type, line(meta), :fun, args}
  end

  # Handle type operator
  defp typespec({:::, meta, [var, expr]}, vars, caller) do
    left = typespec(var, [elem(var, 0) | vars], caller)
    right = typespec(expr, vars, caller)
    {:ann_type, line(meta), [left, right]}
  end

  # Handle unary ops
  defp typespec({op, meta, [integer]}, _, _) when op in [:+, :-] and is_integer(integer) do
    {:op, line(meta), op, {:integer, line(meta), integer}}
  end

  # Handle remote calls in the form of @module_attribute.type.
  # These are not handled by the general remote type clause as calling
  # Macro.expand/2 on the remote does not expand module attributes (but expands
  # things like __MODULE__).
  defp typespec({{:., meta, [{:@, _, [{attr, _, _}]}, name]}, _, args} = orig, vars, caller) do
    remote = Module.get_attribute(caller.module, attr)

    unless is_atom(remote) and remote != nil do
      message =
        "invalid remote in typespec: #{Macro.to_string(orig)} (@#{attr} is #{inspect(remote)})"

      compile_error(caller, message)
    end

    type = {typespec(remote, vars, caller), meta, typespec(name, vars, caller), args}
    remote_type(type, vars, caller)
  end

  # Handle remote calls
  defp typespec({{:., meta, [remote, name]}, _, args} = orig, vars, caller) do
    # We set a function name to avoid tracking
    # aliases in typespecs as compile time dependencies.
    remote = Macro.expand(remote, %{caller | function: {:typespec, 0}})

    unless is_atom(remote) do
      compile_error(caller, "invalid remote in typespec: #{Macro.to_string(orig)}")
    end

    type = {typespec(remote, vars, caller), meta, typespec(name, vars, caller), args}
    remote_type(type, vars, caller)
  end

  # Handle tuples
  defp typespec({:tuple, meta, []}, _vars, _caller) do
    {:type, line(meta), :tuple, :any}
  end

  defp typespec({:{}, meta, t}, vars, caller) when is_list(t) do
    args = for e <- t, do: typespec(e, vars, caller)
    {:type, line(meta), :tuple, args}
  end

  defp typespec({left, right}, vars, caller) do
    typespec({:{}, [], [left, right]}, vars, caller)
  end

  # Handle blocks
  defp typespec({:__block__, _meta, [arg]}, vars, caller) do
    typespec(arg, vars, caller)
  end

  # Handle variables or local calls
  defp typespec({name, meta, atom}, vars, caller) when is_atom(atom) do
    if name in vars do
      {:var, line(meta), name}
    else
      typespec({name, meta, []}, vars, caller)
    end
  end

  # Handle local calls
  defp typespec({:string, meta, arguments}, vars, caller) do
    warning =
      "string() type use is discouraged. " <>
        "For character lists, use charlist() type, for strings, String.t()\n" <>
        Exception.format_stacktrace(Macro.Env.stacktrace(caller))

    :elixir_errors.warn(caller.line, caller.file, warning)

    arguments = for arg <- arguments, do: typespec(arg, vars, caller)
    {:type, line(meta), :string, arguments}
  end

  defp typespec({:nonempty_string, meta, arguments}, vars, caller) do
    warning =
      "nonempty_string() type use is discouraged. " <>
        "For non-empty character lists, use nonempty_charlist() type, for strings, String.t()\n" <>
        Exception.format_stacktrace(Macro.Env.stacktrace(caller))

    :elixir_errors.warn(caller.line, caller.file, warning)

    arguments = for arg <- arguments, do: typespec(arg, vars, caller)
    {:type, line(meta), :nonempty_string, arguments}
  end

  # TODO: Remove char_list type by 2.0
  defp typespec({type, _meta, []}, vars, caller) when type in [:charlist, :char_list] do
    if type == :char_list do
      warning = "the char_list() type is deprecated, use charlist()"
      :elixir_errors.warn(caller.line, caller.file, warning)
    end

    typespec(quote(do: :elixir.charlist()), vars, caller)
  end

  defp typespec({:nonempty_charlist, _meta, []}, vars, caller) do
    typespec(quote(do: :elixir.nonempty_charlist()), vars, caller)
  end

  defp typespec({:struct, _meta, []}, vars, caller) do
    typespec(quote(do: :elixir.struct()), vars, caller)
  end

  defp typespec({:as_boolean, _meta, [arg]}, vars, caller) do
    typespec(quote(do: :elixir.as_boolean(unquote(arg))), vars, caller)
  end

  defp typespec({:keyword, _meta, args}, vars, caller) when length(args) <= 1 do
    typespec(quote(do: :elixir.keyword(unquote_splicing(args))), vars, caller)
  end

  defp typespec({:fun, meta, args}, vars, caller) do
    args = for arg <- args, do: typespec(arg, vars, caller)
    {:type, line(meta), :fun, args}
  end

  defp typespec({name, meta, arguments}, vars, caller) do
    arguments = for arg <- arguments, do: typespec(arg, vars, caller)
    arity = length(arguments)
    type = if :erl_internal.is_type(name, arity), do: :type, else: :user_type
    {type, line(meta), name, arguments}
  end

  # Handle literals
  defp typespec(atom, _, _) when is_atom(atom) do
    {:atom, 0, atom}
  end

  defp typespec(integer, _, _) when is_integer(integer) do
    {:integer, 0, integer}
  end

  defp typespec([], vars, caller) do
    typespec({nil, [], []}, vars, caller)
  end

  defp typespec([{:..., _, atom}], vars, caller) when is_atom(atom) do
    typespec({:nonempty_list, [], []}, vars, caller)
  end

  defp typespec([spec, {:..., _, atom}], vars, caller) when is_atom(atom) do
    typespec({:nonempty_list, [], [spec]}, vars, caller)
  end

  defp typespec([spec], vars, caller) do
    typespec({:list, [], [spec]}, vars, caller)
  end

  defp typespec(list, vars, caller) when is_list(list) do
    [head | tail] = Enum.reverse(list)

    union =
      Enum.reduce(tail, validate_kw(head, list, caller), fn elem, acc ->
        {:|, [], [validate_kw(elem, list, caller), acc]}
      end)

    typespec({:list, [], [union]}, vars, caller)
  end

  defp typespec(other, _vars, caller) do
    compile_error(caller, "unexpected expression in typespec: #{Macro.to_string(other)}")
  end

  ## Helpers

  defp compile_error(caller, desc) do
    raise CompileError, file: caller.file, line: caller.line, description: desc
  end

  defp remote_type({remote, meta, name, arguments}, vars, caller) do
    arguments = for arg <- arguments, do: typespec(arg, vars, caller)
    {:remote_type, line(meta), [remote, name, arguments]}
  end

  defp collect_union({:|, _, [a, b]}), do: [a | collect_union(b)]
  defp collect_union(v), do: [v]

  defp validate_kw({key, _} = t, _, _caller) when is_atom(key), do: t

  defp validate_kw(_, original, caller) do
    compile_error(caller, "unexpected list in typespec: #{Macro.to_string(original)}")
  end

  defp fn_args(meta, args, return, vars, caller) do
    case [fn_args(meta, args, vars, caller), typespec(return, vars, caller)] do
      [{:type, _, :any}, {:type, _, :any, []}] -> []
      x -> x
    end
  end

  defp fn_args(meta, [{:..., _, _}], _vars, _caller) do
    {:type, line(meta), :any}
  end

  defp fn_args(meta, args, vars, caller) do
    args = for arg <- args, do: typespec(arg, vars, caller)
    {:type, line(meta), :product, args}
  end

  defp variable({name, meta, _}) do
    {:var, line(meta), name}
  end
end
