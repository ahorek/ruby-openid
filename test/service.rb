require 'test/unit'
require "openid/service"

class FakeYadis
  
  def uri
    return ''
  end
  
end

class OpenIDServiceEndpointTestCase < Test::Unit::TestCase

  def test_parse
    File.open('data/brian.xrds') do |f|
      xrds = XRDS.new(f.read)
      assert_not_nil(xrds)
      assert_equal(xrds.services.length, 1)
      
      service = xrds.services[0]
      service.yadis = FakeYadis.new

      openid_service = OpenID::OpenIDServiceEndpoint.from_endpoint(service)
      assert_not_nil(openid_service)
      assert_equal(openid_service.server_url, 'http://www.myopenid.com/server')
    end
  end

end

