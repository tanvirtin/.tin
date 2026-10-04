local operation_token = {}

function operation_token.new()
  return { count = 0 }
end

function operation_token.bump(token)
  token.count = token.count + 1

  return token.count
end

function operation_token.stale(token, ticket)
  return token.count ~= ticket
end

return operation_token
