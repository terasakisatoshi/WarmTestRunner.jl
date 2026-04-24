module VirtualExecutionFixture

module UpstreamName
export token
token() = :upstream
end

module Wrapper
export UpstreamName
module UpstreamName
export token
token() = :wrapped
end
end

add1(x) = x + 1

end
