defmodule Synapse.Workspace.ReadRequest do
  @moduledoc """
  A bounded one-based text window requested from an opened Workspace.

  Tool creates this from validated model arguments. Workspace revalidates it and
  later resolves `path` under the trusted root. `line_count` and `max_bytes` may
  lower but never raise the handle's limits.

  ## Example

      iex> {:ok, request} = Synapse.Workspace.ReadRequest.new(%{
      ...>   path: "lib/synapse.ex",
      ...>   start_line: 1,
      ...>   line_count: 50
      ...> })
      iex> {request.path, request.start_line, request.line_count}
      {"lib/synapse.ex", 1, 50}
  """

  alias Synapse.Workspace.{Limits, Validation}

  @enforce_keys [:path, :start_line, :line_count, :max_bytes]
  defstruct [:path, :start_line, :line_count, :max_bytes]

  @typedoc "A validated relative path and bounded line/byte window."
  @type t :: %__MODULE__{
          path: String.t(),
          start_line: pos_integer(),
          line_count: pos_integer(),
          max_bytes: pos_integer()
        }

  @typedoc "A field-specific invalid read request."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:path, :must_be_bounded_relative_path}
          | {:start_line, :must_be_positive_integer}
          | {:line_count, :must_be_within_workspace_limit}
          | {:max_bytes, :must_be_within_workspace_limit}

  @doc "Validates a read request against one Workspace's ceilings."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [:path, :start_line, :line_count, :max_bytes]

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         start_line <- Map.get(attrs, :start_line, 1),
         line_count <- Map.get(attrs, :line_count, limits.default_read_lines),
         max_bytes <- Map.get(attrs, :max_bytes, limits.default_read_bytes),
         true <-
           Validation.relative_path?(attrs[:path], limits.max_path_bytes) or
             {:error, {:path, :must_be_bounded_relative_path}},
         true <-
           Validation.positive_int64?(start_line) or
             {:error, {:start_line, :must_be_positive_integer}},
         true <-
           (is_integer(line_count) and line_count > 0 and line_count <= limits.max_read_lines) or
             {:error, {:line_count, :must_be_within_workspace_limit}},
         true <-
           (is_integer(max_bytes) and max_bytes > 0 and max_bytes <= limits.max_read_bytes) or
             {:error, {:max_bytes, :must_be_within_workspace_limit}} do
      {:ok,
       %__MODULE__{
         path: attrs.path,
         start_line: start_line,
         line_count: line_count,
         max_bytes: max_bytes
       }}
    end
  end
end

defmodule Synapse.Workspace.ReadLine do
  @moduledoc """
  One numbered text line returned by Workspace.

  `text` excludes the terminator, `ending` records LF/CRLF/EOF form, and
  `truncated` means some source bytes did not fit the byte window. Usually that
  includes an unavailable text suffix; for an empty CRLF line it may include only
  terminator bytes while the ending remains available as metadata. Workspace
  creates this value; Tool formats it for the model.
  """

  alias Synapse.Workspace.{Limits, Validation}

  @enforce_keys [:number, :text, :ending, :truncated]
  defstruct [:number, :text, :ending, :truncated]

  @typedoc "The line-ending form observed in the source file."
  @type ending :: :lf | :crlf | :none

  @typedoc "A bounded UTF-8 line observation."
  @type t :: %__MODULE__{
          number: pos_integer(),
          text: String.t(),
          ending: ending(),
          truncated: boolean()
        }

  @typedoc "A field-specific invalid line result."
  @type validation_error :: {atom(), atom()} | {:unknown_fields, [term()]}

  @doc "Validates one Workspace-produced line against the read byte ceiling."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [:number, :text, :ending, :truncated]

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         true <-
           Validation.positive_int64?(attrs[:number]) or
             {:error, {:number, :must_be_positive_integer}},
         true <-
           Validation.bounded_string?(attrs[:text], limits.max_read_bytes) or
             {:error, {:text, :must_be_bounded_utf8}},
         true <- attrs[:ending] in [:lf, :crlf, :none] or {:error, {:ending, :must_be_known}},
         true <-
           is_boolean(attrs[:truncated]) or {:error, {:truncated, :must_be_boolean}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end
end

defmodule Synapse.Workspace.ReadResult do
  @moduledoc """
  A bounded numbered read and opaque revision from one observed file state.

  Workspace creates this only after path, encoding, race, and revision checks.
  `next_line` is the next physical line or `nil` at EOF; it never points
  into a clipped long-line suffix.
  """

  alias Synapse.Workspace.{Limits, ReadLine, Revision, Validation}

  @enforce_keys [:path, :revision, :lines, :next_line, :file_bytes]
  defstruct [:path, :revision, :lines, :next_line, :file_bytes]

  @typedoc "The complete structured result of one bounded Workspace read."
  @type t :: %__MODULE__{
          path: String.t(),
          revision: Revision.t(),
          lines: [ReadLine.t()],
          next_line: pos_integer() | nil,
          file_bytes: non_neg_integer()
        }

  @typedoc "A field-specific invalid read result."
  @type validation_error :: {atom(), atom()} | {:unknown_fields, [term()]}

  @doc "Validates a Workspace-produced read result and its aggregate bounds."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [:path, :revision, :lines, :next_line, :file_bytes]

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         true <-
           Validation.relative_path?(attrs[:path], limits.max_path_bytes) or
             {:error, {:path, :must_be_bounded_relative_path}},
         true <-
           Revision.valid?(attrs[:revision]) or
             {:error, {:revision, :must_be_workspace_revision}},
         true <-
           (Validation.bounded_proper_list?(attrs[:lines], limits.max_read_lines) and
              Enum.all?(attrs.lines, &valid_read_line?(&1, limits)) and
              Enum.reduce(attrs.lines, 0, &(read_line_bytes(&1) + &2)) <= limits.max_read_bytes and
              valid_line_sequence?(attrs.lines) and valid_line_states?(attrs.lines)) or
             {:error, {:lines, :must_be_bounded_read_lines}},
         true <-
           is_nil(attrs[:next_line]) or Validation.positive_int64?(attrs[:next_line]) or
             {:error, {:next_line, :must_be_positive_integer_or_nil}},
         true <-
           valid_next_line?(attrs[:lines], attrs[:next_line]) or
             {:error, {:next_line, :must_follow_returned_lines}},
         true <-
           (is_integer(attrs[:file_bytes]) and attrs.file_bytes >= 0 and
              attrs.file_bytes <= limits.max_file_bytes and
              attrs.file_bytes >= Enum.reduce(attrs[:lines], 0, &(read_line_bytes(&1) + &2))) or
             {:error, {:file_bytes, :must_be_within_workspace_limit}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  defp valid_read_line?(%ReadLine{} = line, limits),
    do: match?({:ok, %ReadLine{}}, ReadLine.new(Map.from_struct(line), limits))

  defp valid_read_line?(_line, _limits), do: false

  defp read_line_bytes(%ReadLine{text: text, truncated: true}), do: byte_size(text)

  defp read_line_bytes(%ReadLine{text: text, ending: ending}),
    do: byte_size(text) + if(ending == :crlf, do: 2, else: if(ending == :lf, do: 1, else: 0))

  defp valid_line_sequence?([]), do: true

  defp valid_line_sequence?([first | rest]) do
    rest
    |> Enum.reduce_while(first.number, fn line, previous ->
      if line.number == previous + 1, do: {:cont, line.number}, else: {:halt, :invalid}
    end)
    |> Kernel.!=(:invalid)
  end

  defp valid_line_states?([]), do: true

  defp valid_line_states?(lines) do
    lines
    |> Enum.drop(-1)
    |> Enum.all?(&(not &1.truncated and &1.ending != :none))
  end

  defp valid_next_line?([], nil), do: true
  defp valid_next_line?([], _next_line), do: false

  defp valid_next_line?(lines, next_line) do
    last = List.last(lines)

    if last.ending == :none,
      do: is_nil(next_line),
      else: is_nil(next_line) or next_line == last.number + 1
  end
end

defmodule Synapse.Workspace.WriteRequest do
  @moduledoc """
  A revision-checked whole-file creation or replacement request.

  `:missing` explicitly requests creation. Replacing an existing file requires
  the opaque Revision returned by a prior read; blind replacement is absent.
  Tool creates this value and MutationServer revalidates it before commit.
  """

  alias Synapse.Workspace.{Limits, Revision, Validation}

  @enforce_keys [:path, :content, :expected_revision]
  defstruct [:path, :content, :expected_revision]

  @typedoc "The required existing or missing file-state expectation."
  @type expectation :: :missing | Revision.t()

  @typedoc "A bounded UTF-8 create or replacement request."
  @type t :: %__MODULE__{
          path: String.t(),
          content: String.t(),
          expected_revision: expectation()
        }

  @typedoc "A field-specific invalid write request."
  @type validation_error :: {atom(), atom()} | {:unknown_fields, [term()]}

  @doc "Validates write content, path shape, and explicit revision expectation."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [:path, :content, :expected_revision]

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         true <-
           Validation.relative_path?(attrs[:path], limits.max_path_bytes) or
             {:error, {:path, :must_be_bounded_relative_path}},
         true <-
           Validation.bounded_string?(attrs[:content], limits.max_file_bytes) or
             {:error, {:content, :must_be_bounded_utf8}},
         true <-
           attrs[:expected_revision] == :missing or
             Revision.valid?(attrs[:expected_revision]) or
             {:error, {:expected_revision, :must_be_missing_or_revision}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end
end

defmodule Synapse.Workspace.EditRequest do
  @moduledoc """
  A revision-checked exact-one-match text replacement request.

  The old text is non-empty and must match exactly once after MutationServer
  confirms the revision. Workspace performs no fuzzy matching, regex expansion,
  or automatic stale merge. Generated complete content is validated and committed
  through the same staged atomic replacement protocol as a whole-file write.
  """

  alias Synapse.Workspace.{Limits, Revision, Validation}

  @enforce_keys [:path, :old_text, :new_text, :expected_revision]
  defstruct [:path, :old_text, :new_text, :expected_revision]

  @typedoc "A bounded exact edit based on one observed revision."
  @type t :: %__MODULE__{
          path: String.t(),
          old_text: String.t(),
          new_text: String.t(),
          expected_revision: Revision.t()
        }

  @typedoc "A field-specific invalid edit request."
  @type validation_error :: {atom(), atom()} | {:unknown_fields, [term()]}

  @doc "Validates exact edit text and mandatory revision shape."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [:path, :old_text, :new_text, :expected_revision]

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         true <-
           Validation.relative_path?(attrs[:path], limits.max_path_bytes) or
             {:error, {:path, :must_be_bounded_relative_path}},
         true <-
           Validation.bounded_string?(attrs[:old_text], limits.max_file_bytes, false) or
             {:error, {:old_text, :must_be_bounded_non_empty_utf8}},
         true <-
           Validation.bounded_string?(attrs[:new_text], limits.max_file_bytes) or
             {:error, {:new_text, :must_be_bounded_utf8}},
         true <-
           Revision.valid?(attrs[:expected_revision]) or
             {:error, {:expected_revision, :must_be_revision}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end
end

defmodule Synapse.Workspace.MutationResult do
  @moduledoc """
  Structured known outcome of one Workspace file mutation.

  It carries relative identity, previous/new revisions, bytes, change state, and
  a separately bounded UTF-8 diff. Ambiguous outcomes are Workspace Errors and
  never use this success contract.
  """

  alias Synapse.Workspace.{Limits, Revision, Validation}

  @enforce_keys [
    :operation_id,
    :path,
    :previous_revision,
    :revision,
    :bytes_written,
    :changed,
    :diff,
    :diff_truncated
  ]
  defstruct @enforce_keys

  @typedoc "A successful known create, replacement, or exact edit outcome."
  @type t :: %__MODULE__{
          operation_id: String.t(),
          path: String.t(),
          previous_revision: :missing | Revision.t(),
          revision: Revision.t(),
          bytes_written: non_neg_integer(),
          changed: boolean(),
          diff: String.t(),
          diff_truncated: boolean()
        }

  @typedoc "A field-specific invalid mutation result."
  @type validation_error :: {atom(), atom()} | {:unknown_fields, [term()]}

  @doc "Validates a Workspace-produced known mutation result and diff bounds."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = @enforce_keys

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         true <-
           Validation.bounded_string?(
             attrs[:operation_id],
             limits.max_operation_id_bytes,
             false
           ) or {:error, {:operation_id, :must_be_bounded_non_empty_string}},
         true <-
           Validation.relative_path?(attrs[:path], limits.max_path_bytes) or
             {:error, {:path, :must_be_bounded_relative_path}},
         true <-
           attrs[:previous_revision] == :missing or
             Revision.valid?(attrs[:previous_revision]) or
             {:error, {:previous_revision, :must_be_missing_or_revision}},
         true <-
           Revision.valid?(attrs[:revision]) or
             {:error, {:revision, :must_be_workspace_revision}},
         true <-
           (is_integer(attrs[:bytes_written]) and attrs.bytes_written >= 0 and
              attrs.bytes_written <= limits.max_file_bytes) or
             {:error, {:bytes_written, :must_be_within_workspace_limit}},
         true <- is_boolean(attrs[:changed]) or {:error, {:changed, :must_be_boolean}},
         true <-
           Validation.bounded_string?(attrs[:diff], limits.max_diff_bytes) or
             {:error, {:diff, :must_be_bounded_utf8}},
         true <-
           is_boolean(attrs[:diff_truncated]) or
             {:error, {:diff_truncated, :must_be_boolean}},
         true <- valid_change_state?(attrs) or {:error, {:changed, :must_match_result}} do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  defp valid_change_state?(%{changed: true, previous_revision: :missing} = attrs),
    do: attrs.diff != ""

  defp valid_change_state?(%{changed: true} = attrs),
    do: attrs.previous_revision != attrs.revision and attrs.diff != ""

  defp valid_change_state?(attrs) do
    attrs.bytes_written == 0 and attrs.diff == "" and not attrs.diff_truncated and
      attrs.previous_revision != :missing and attrs.previous_revision == attrs.revision
  end
end
