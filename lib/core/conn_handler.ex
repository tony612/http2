defprotocol HTTP2.ConnHandler do
  @spec handle(any, atom, any) :: any
  @fallback_to_any true
  def handle(type, name, args)
end

defimpl HTTP2.ConnHandler, for: Any do
  def handle(_, _, _), do: nil
end
