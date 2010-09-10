#
# Author:: Bryan McLellan (btm@loftninjas.org), Jesse Nelson (spheromak@gmail.com)
# Copyright:: Copyright (c) 2009 Bryan McLellan
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/log'
require 'chef/mixin/command'
require 'chef/provider'
require 'ipaddr'

class Chef::Provider::Route < Chef::Provider
    include Chef::Mixin::Command

    attr_accessor :is_running

    MASK = {'0.0.0.0'          => '0',
            '128.0.0.0'        => '1',
            '192.0.0.0'        => '2',
            '224.0.0.0'        => '3',
            '240.0.0.0'        => '4',
            '248.0.0.0'        => '5',
            '252.0.0.0'        => '6',
            '254.0.0.0'        => '7',
            '255.0.0.0'        => '8',
            '255.128.0.0'      => '9',
            '255.192.0.0'      => '10',
            '255.224.0.0'      => '11',
            '255.240.0.0'      => '12',
            '255.248.0.0'      => '13',
            '255.252.0.0'      => '14',
            '255.254.0.0'      => '15',
            '255.255.0.0'      => '16',
            '255.255.128.0'    => '17',
            '255.255.192.0'    => '18',
            '255.255.224.0'    => '19',
            '255.255.240.0'    => '20',
            '255.255.248.0'    => '21',
            '255.255.252.0'    => '22',
            '255.255.254.0'    => '23',
            '255.255.255.0'    => '24',
            '255.255.255.128'  => '25',
            '255.255.255.192'  => '26',
            '255.255.255.224'  => '27',
            '255.255.255.240'  => '28',
            '255.255.255.248'  => '29',
            '255.255.255.252'  => '30',
            '255.255.255.254'  => '31',
            '255.255.255.255'  => '32' }

  def load_current_resource
    @route_exists = nil

    Chef::Log.info("in load_current_resource  name=#{@new_resource.name}, gateway=#{@new_resource.gateway}")

    case node[:os] 
    when "linux"
      @route_exists=true if find_running_route_linux(:name=>@new_resource.name,
                              :netmask=>@new_resource.netmask,
                              :gateway=>@new_resource.gateway,
                              :device=>@new_resource.device)
    end
  end

  def find_running_route_linux(route_spec)
    route_file = ::File.open("/proc/net/route", "r")
    while (line = route_file.gets)
      # proc layout
      iface,destination,gateway,flags,refcnt,use,metric,mask,mtu,window,irtt = line.split
      next if irtt == "IRTT"

      #Chef::Log.info("destination=#{destination},mask=#{mask}")
      running_route = {:name=> htoa(destination),
                       :netmask=> htoa(mask),
                       :gateway=> htoa(gateway),
                       :device=> iface}

      return running_route if compare_route(route_spec,running_route)
    end
    route_file.close
    return nil
  end

  # cidr or quad dot mask
  def get_ip(addr, mask)
    # should bitch here if there is a / in addr and  mask is also set.
    if (addr =~ /\// &&  mask)
      raise Chef::Exceptions::Route, "Cannot modify #{@new_resource} Adress is in CIDR format and  mask was also provided"
    end
    return IPAddr.new("#{addr}/#{mask}") if mask
    return IPAddr.new(addr)
  end

  def compare_route(route1,route2)
    route1_ip = get_ip(route1[:name], route1[:netmask])
    route2_ip = get_ip(route2[:name], route2[:netmask])
    if (route1_ip == route2_ip && route1[:gateway] == route2[:gateway]) 
      if (route1[:device] == route2[:device]) or (route1[:device].to_s.empty?) or (route2[:device].to_s.empty?) 
         return true
      end
    end
    return false
  end

  def action_add
    unless @route_exists
      command = generate_command(:add)
      Chef::Log.info("Adding route: #{command}")
      run_command( :command => command )
      @new_resource.updated = true
      generate_config
    else
      Chef::Log.info("Route #{command} already exists")
    end
  end

  def action_delete
    if @route_exists
      command = generate_command(:delete)
      Chef::Log.info("Removing route: #{command}")
      run_command( :command => command )
      @new_resource.updated = true
      generate_config
    else
      Chef::Log.debug("Route #{@new_resource.name} does not exist")
    end
  end

  def generate_config
    conf = Hash.new
    # walk the collection load up conf hash with all the routes we
    # should write
    position = 0
    run_context.resource_collection.each do |resource|  
      if resource.is_a? Chef::Resource::Route
        dev = resource.device ? resource.device : default_dev(:name => resource.name, 
                                                              :netmask => resource.netmask, 
                                                              :gateway => resource.gateway)
        conf[dev] ||= ''
        if resource.action == :add
          conf[dev] << config_file_contents(:add, :position=>position, 
            :target => resource.name, :netmask => resource.netmask, :gateway => resource.gateway)
          position = position + 1
        end
      end
    end

    # add new platform configs here
    case node[:platform]
    when "centos", "redhat", "fedora", "xenserver"
      generate_redhat(conf)
    else 
      Chef::Log.warn("#{node[:platform]} not supported by Route provider (yet) can't generate a config file")
    end
  end

  def generate_redhat(conf)
    conf.each do |k, v|
      network_file = ::File.new("/etc/sysconfig/network-scripts/route-#{k}", "w")
      network_file.puts(conf[k])
      Chef::Log.debug("writing route.#{k}\n#{conf[k]}")
      network_file.close
    end
  end

  def generate_command(action)
    #todo: should set this up per-sys type
    common_route_items = ''
    common_route_items << "/#{MASK[@new_resource.netmask.to_s]}" if @new_resource.netmask
    common_route_items << " via #{@new_resource.gateway}" if @new_resource.gateway

    case action
    when :add
      command = "ip route replace #{@new_resource.name}"
      command << common_route_items
      command << " dev #{@new_resource.device}" if @new_resource.device
    when :delete
      command = "ip route delete #{@new_resource.name}"
      command << common_route_items
    end

    return command
  end

  def config_file_contents(action, options={})
    content = ''
    case action
    when :add
      content << "ADDRESS#{options[:position]}=#{options[:target]}\n"
      content << "NETMASK#{options[:position]}=#{options[:netmask]}\n"
      content << "GATEWAY#{options[:position]}=#{options[:gateway]}\n" 
    end

    return content
  end
 
  def default_dev(route_spec)
    case node[:os]
    when "linux"
      running_route = find_running_route_linux(route_spec) 
      if running_route
        return running_route[:device]
      else
        return "eth0"
      end
    when "darwin"
      return "en0"
    end
  end

  def htoa(packed)
    IPAddr.new(packed.scan(/../).reverse.to_s.hex, Socket::AF_INET).to_s
  end
end
