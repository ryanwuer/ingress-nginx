local ngx_re_split = require("ngx.re").split
local string_format = string.format
local string_lower = string.lower
local string_gsub = string.gsub
local ipairs = ipairs
local pairs = pairs

local ngx_log = ngx.log
local ngx_INFO = ngx.INFO
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN

local HOSTS_PATH = "/etc/hosts"

local _M = {}
local hosts_cache = {}
local last_modified = 0

-- 检查IP地址是否为IPv4格式
local function is_ipv4(ip)
  return ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

-- 检查IP地址是否为IPv6格式
local function is_ipv6(ip)
  -- 简化的IPv6检查，包含冒号且不是IPv4
  return ip:find(":") ~= nil and not is_ipv4(ip)
end

-- 解析hosts文件中的一行
local function parse_hosts_line(line)
  -- 移除注释
  local comment_pos = line:find("#")
  if comment_pos then
    line = line:sub(1, comment_pos - 1)
  end
  
  -- 去除首尾空白
  line = string_gsub(line, "^%s+", "")
  line = string_gsub(line, "%s+$", "")
  
  -- 跳过空行
  if line == "" then
    return nil
  end
  
  -- 分割行为字段
  local parts, err = ngx_re_split(line, "\\s+")
  if err or not parts or #parts < 2 then
    return nil
  end
  
  local ip = parts[1]
  local hostnames = {}
  
  -- 验证IP地址格式
  if not (is_ipv4(ip) or is_ipv6(ip)) then
    return nil
  end
  
  -- 收集所有主机名
  for i = 2, #parts do
    if parts[i] and parts[i] ~= "" then
      -- 将主机名转换为小写以便不区分大小写匹配
      table.insert(hostnames, string_lower(parts[i]))
    end
  end
  
  return ip, hostnames
end

-- 读取并解析hosts文件
local function load_hosts_file()
  local f, err = io.open(HOSTS_PATH, "r")
  if not f then
    ngx_log(ngx_WARN, "could not open ", HOSTS_PATH, ": ", tostring(err))
    return {}
  end
  
  local new_hosts = {}
  local line_count = 0
  
  for line in f:lines() do
    line_count = line_count + 1
    local ip, hostnames = parse_hosts_line(line)
    
    if ip and hostnames then
      for _, hostname in ipairs(hostnames) do
        if not new_hosts[hostname] then
          new_hosts[hostname] = {}
        end
        table.insert(new_hosts[hostname], ip)
      end
    end
  end
  
  f:close()
  
  ngx_log(ngx_INFO, "loaded ", HOSTS_PATH, " with ", line_count, " lines")
  return new_hosts
end

-- 获取文件的修改时间
local function get_file_mtime(filepath)
  local attr = lfs and lfs.attributes(filepath, "modification")
  return attr or 0
end

-- 检查hosts文件是否需要重新加载
local function should_reload_hosts()
  local current_mtime = get_file_mtime(HOSTS_PATH)
  return current_mtime > last_modified
end

-- 重新加载hosts文件（如果需要）
local function reload_hosts_if_needed()
  if should_reload_hosts() then
    hosts_cache = load_hosts_file()
    last_modified = get_file_mtime(HOSTS_PATH)
    ngx_log(ngx_INFO, "reloaded hosts file due to modification")
  end
end

-- 从hosts文件查找主机名对应的IP地址
function _M.lookup(hostname)
  if not hostname or hostname == "" then
    return nil
  end
  
  -- 重新加载hosts文件（如果需要）
  reload_hosts_if_needed()
  
  -- 转换为小写进行查找
  local lower_hostname = string_lower(hostname)
  local ips = hosts_cache[lower_hostname]
  
  if ips and #ips > 0 then
    ngx_log(ngx_INFO, "found ", hostname, " in hosts file: ", table.concat(ips, ", "))
    return ips
  end
  
  return nil
end

-- 检查主机名是否存在于hosts文件中
function _M.exists(hostname)
  if not hostname or hostname == "" then
    return false
  end
  
  reload_hosts_if_needed()
  local lower_hostname = string_lower(hostname)
  return hosts_cache[lower_hostname] ~= nil
end

-- 获取所有hosts条目（用于调试）
function _M.get_all_hosts()
  reload_hosts_if_needed()
  return hosts_cache
end

-- 强制重新加载hosts文件
function _M.reload()
  hosts_cache = load_hosts_file()
  last_modified = get_file_mtime(HOSTS_PATH)
  ngx_log(ngx_INFO, "force reloaded hosts file")
end

-- 初始化：加载hosts文件
do
  -- 尝试加载lfs模块用于文件时间检查
  local ok
  ok, lfs = pcall(require, "lfs")
  if not ok then
    ngx_log(ngx_WARN, "lfs module not available, hosts file modification time checking disabled")
    lfs = nil
  end
  
  -- 初始加载hosts文件
  hosts_cache = load_hosts_file()
  last_modified = get_file_mtime(HOSTS_PATH)
end

return _M
