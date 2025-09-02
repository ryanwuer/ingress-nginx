local original_ngx = ngx
local hosts

local function reset_ngx()
  _G.ngx = original_ngx
end

local function mock_ngx(mock)
  local _ngx = mock
  setmetatable(_ngx, { __index = ngx })
  _G.ngx = _ngx
end

-- 模拟 ngx.re.split
local function mock_ngx_re_split(str, pattern)
  local result = {}
  if pattern == "\\s+" then
    for word in str:gmatch("%S+") do
      table.insert(result, word)
    end
  end
  return result
end

-- 模拟 lfs 模块
local function mock_lfs()
  return {
    attributes = function(filepath, attr)
      if attr == "modification" then
        return os.time()
      end
      return nil
    end
  }
end

-- 模拟 io.open 来读取测试用的 hosts 内容
local test_hosts_content = [[
# Test hosts file
127.0.0.1   localhost
127.0.0.1   localhost.localdomain
::1         localhost ip6-localhost ip6-loopback

# Custom entries for testing
192.168.1.100   example.com www.example.com
192.168.1.101   test.local
2001:db8::1     ipv6.example.com
10.0.0.50       my-service.default.svc.cluster.local my-service

# ExternalName test entries
203.0.113.10    external-api.example.org
203.0.113.11    another-service.example.net api.another-service.example.net

# Invalid lines for testing
# This is a comment
invalid-line-without-ip
  # Another comment with leading spaces
]]

local function mock_io_open(filepath, mode)
  if filepath == "/etc/hosts" and mode == "r" then
    local lines = {}
    for line in test_hosts_content:gmatch("[^\n]+") do
      table.insert(lines, line)
    end
    
    local line_index = 0
    return {
      lines = function()
        return function()
          line_index = line_index + 1
          return lines[line_index]
        end
      end,
      close = function() end
    }
  end
  return nil
end

describe("hosts", function()
  
  before_each(function()
    -- 模拟 ngx 对象
    mock_ngx({
      log = function(level, ...)
        -- 静默日志输出
      end,
      INFO = "INFO",
      WARN = "WARN",
      ERR = "ERR"
    })
    
    -- 模拟必要的全局函数和模块
    _G.require = function(module)
      if module == "ngx.re" then
        return { split = mock_ngx_re_split }
      elseif module == "lfs" then
        return mock_lfs()
      end
      return original_require(module)
    end
    
    -- 模拟 io.open
    local original_io_open = io.open
    _G.io.open = mock_io_open
    
    -- 重新加载 hosts 模块
    package.loaded["util.hosts"] = nil
    hosts = require("util.hosts")
    
    -- 恢复 io.open
    _G.io.open = original_io_open
  end)

  after_each(function()
    reset_ngx()
  end)

  describe("lookup", function()
    
    it("should resolve localhost to 127.0.0.1", function()
      local result = hosts.lookup("localhost")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("127.0.0.1", result[1])
    end)
    
    it("should resolve example.com to 192.168.1.100", function()
      local result = hosts.lookup("example.com")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("192.168.1.100", result[1])
    end)
    
    it("should resolve www.example.com to 192.168.1.100", function()
      local result = hosts.lookup("www.example.com")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("192.168.1.100", result[1])
    end)
    
    it("should resolve IPv6 addresses", function()
      local result = hosts.lookup("ipv6.example.com")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("2001:db8::1", result[1])
    end)
    
    it("should resolve Kubernetes service names", function()
      local result = hosts.lookup("my-service.default.svc.cluster.local")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("10.0.0.50", result[1])
      
      -- 测试短名称
      result = hosts.lookup("my-service")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("10.0.0.50", result[1])
    end)
    
    it("should resolve ExternalName services", function()
      local result = hosts.lookup("external-api.example.org")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("203.0.113.10", result[1])
      
      result = hosts.lookup("another-service.example.net")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("203.0.113.11", result[1])
      
      result = hosts.lookup("api.another-service.example.net")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("203.0.113.11", result[1])
    end)
    
    it("should be case insensitive", function()
      local result = hosts.lookup("EXAMPLE.COM")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("192.168.1.100", result[1])
      
      result = hosts.lookup("Test.Local")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("192.168.1.101", result[1])
    end)
    
    it("should return nil for non-existent hosts", function()
      local result = hosts.lookup("nonexistent.example.com")
      assert.is_nil(result)
    end)
    
    it("should handle empty or nil input", function()
      local result = hosts.lookup("")
      assert.is_nil(result)
      
      result = hosts.lookup(nil)
      assert.is_nil(result)
    end)
    
    it("should handle IPv6 localhost", function()
      local result = hosts.lookup("ip6-localhost")
      assert.is_not_nil(result)
      assert.is_table(result)
      assert.equals("::1", result[1])
    end)
    
  end)
  
  describe("exists", function()
    
    it("should return true for existing hosts", function()
      assert.is_true(hosts.exists("localhost"))
      assert.is_true(hosts.exists("example.com"))
      assert.is_true(hosts.exists("EXAMPLE.COM"))  -- case insensitive
    end)
    
    it("should return false for non-existing hosts", function()
      assert.is_false(hosts.exists("nonexistent.example.com"))
      assert.is_false(hosts.exists(""))
      assert.is_false(hosts.exists(nil))
    end)
    
  end)
  
  describe("multiple IPs for single hostname", function()
    
    it("should handle multiple aliases for same IP", function()
      -- localhost 应该同时匹配 localhost 和 localhost.localdomain
      local result1 = hosts.lookup("localhost")
      local result2 = hosts.lookup("localhost.localdomain")
      
      assert.is_not_nil(result1)
      assert.is_not_nil(result2)
      assert.equals(result1[1], result2[1])
    end)
    
  end)
  
end)
