# Recursively expand embedded JSON-in-a-string (a webhook's "body") into real
# nesting. The `[{` guard stops "1800000.00" from being reparsed as a number.
def inflate:
  if type == "object" then map_values(inflate)
  elif type == "array" then map(inflate)
  elif type == "string"
    and test("^\\s*[\\[{]")
    and (try (fromjson | type | . == "object" or . == "array") catch false)
  then (fromjson | inflate)
  else . end;
inflate
