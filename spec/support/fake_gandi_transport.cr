# Transport HTTP factice pour tester Beryl::Providers::Gandi sans réseau.
# Namespacé pour éviter tout conflit avec d'autres FakeTransport.
require "api-gandi"

class FakeGandiTransport < GandiApi::HttpTransport
  record Request, method : String, url : String, body : String
  getter requests = [] of Request
  property status : Int32 = 201
  property response_body : String = ""

  def request(method, url, headers, body) : {Int32, String}
    @requests << Request.new(method, url, body)
    {@status, @response_body}
  end

  def last : Request
    @requests.last
  end
end

def build_fake_gandi_client(transport : FakeGandiTransport) : GandiApi::Client
  GandiApi::Client.new(token: "pat-test", transport: transport)
end
