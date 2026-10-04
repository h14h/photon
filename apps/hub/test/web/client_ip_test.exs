defmodule PhotonWeb.ClientIPTest do
  @moduledoc "Where a request came from, behind the hub's own TLS proxy or not."

  use ExUnit.Case, async: true

  alias PhotonWeb.ClientIP

  test "trusts the address the local proxy forwarded" do
    assert ClientIP.client({127, 0, 0, 1}, [{"x-forwarded-for", "100.64.0.9"}]) ==
             {100, 64, 0, 9}

    assert ClientIP.client({0, 0, 0, 0, 0, 0, 0, 1}, [{"x-forwarded-for", "fd7a::9"}]) ==
             {64_890, 0, 0, 0, 0, 0, 0, 9}
  end

  test "takes the last forwarded address, the one the proxy added" do
    headers = [{"x-forwarded-for", "1.2.3.4, 100.64.0.8"}, {"x-forwarded-for", "100.64.0.9"}]
    assert ClientIP.client({127, 0, 0, 1}, headers) == {100, 64, 0, 9}
  end

  test "a loopback request without a forwarded address is the hub machine itself" do
    assert ClientIP.client({127, 0, 0, 1}, []) == :local
    assert ClientIP.client({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, []) == :local
  end

  test "ignores what anyone but the local proxy says about itself" do
    assert ClientIP.client({100, 64, 0, 5}, [{"x-forwarded-for", "100.64.0.9"}]) ==
             {100, 64, 0, 5}
  end

  test "an address the proxy forwarded that can't be read is nobody" do
    assert ClientIP.client({127, 0, 0, 1}, [{"x-forwarded-for", "not-an-ip"}]) == nil
  end
end
