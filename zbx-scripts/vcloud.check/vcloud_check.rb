#!/usr/bin/env ruby
=begin

Script: vcloud.check
Version: 1.0
Author: Jean-Jacques Martrès (jjmartres |at| gmail |dot| com)
Description: This script query the vCloud Director API to get information on Virtual Datacenters (vDC)
License: GPL2

This script is intended for use with Zabbix > 2.0

USAGE:
  as a script:          vcloud.check [options]
  as an item:           vcloud.check["-q","RBLS|IP_ADDRESS"]

OPTIONS
    -h, --help                       Display this help message
    -u, --url URL                    vCloud url to connect to
    -l, --login USERNAME             vCloud username
    -p, --password PASSWORD          vCloud password
    -o, --organization ORGANIZATION  vCloud organization
    -q, --query QUERIES              Query to pass to your vCloud. List of supported queries :
           organizations.discovery
           vdcs.discovery
           vdc.organization
           vdc.isenabled
           vdc.description
           vdc.allocationmodel
           vdc.cpu_units
           vdc.cpu_allocated
           vdc.cpu_limit
           vdc.cpu_reserved
           vdc.cpu_used
           vdc.cpu_overhead
           vdc.memory_units
           vdc.memory_allocated
           vdc.memory_limit
           vdc.memory_reserved
           vdc.memory_used
           vdc.memory_overhead
           vdc.vm_quota
           vdc.vm_running
           vdc.vm_created
           vdc.network_nicquota
           vdc.network_quota
           vdc.network_usednetworkcount
           vdc.storage_profiles
           vdc.storage_profile_limit
           vdc.storage_profile_enabled
           vdc.storage_profile_default
    -i, --items ITEMs                Comma separated list of items to query on vCloud
=end

require 'rubygems'
require 'rest-client'
require 'nokogiri'
require 'httpclient'
require 'optparse'
require 'json'

QUERIES = %w(
  organizations.discovery
  vdcs.discovery
  vdc.organization
  vdc.isenabled
  vdc.description
  vdc.allocationmodel
  vdc.cpu_units
  vdc.cpu_allocated
  vdc.cpu_limit
  vdc.cpu_reserved
  vdc.cpu_used
  vdc.cpu_overhead
  vdc.memory_units
  vdc.memory_allocated
  vdc.memory_limit
  vdc.memory_reserved
  vdc.memory_used
  vdc.memory_overhead
  vdc.vm_quota
  vdc.vm_running
  vdc.vm_created
  vdc.network_nicquota
  vdc.network_quota
  vdc.network_usednetworkcount
  vdc.storage_profiles
  vdc.storage_profile_limit
  vdc.storage_profile_enabled
  vdc.storage_profile_default
  providervdc.query
)

class Hash
  def downcase_key
    keys.each do |k|
      store(k.to_s.downcase.to_sym, Array === (v = delete(k)) ? v.map(&:downcase_key) : v)
    end
    self
  end

  class << self

    def from_xml(xml_io)
      begin
        result = Nokogiri::XML(xml_io)
        return { result.root.name.to_sym => xml_node_to_hash(result.root)}
      rescue Exception => e
        # raise your custom exception here
      end
    end

    def xml_node_to_hash(node)
      # If we are at the root of the document, start the hash
      if node.element?
        result_hash = {}
        if node.attributes != {}
          attributes = {}
          node.attributes.keys.each do |key|
            attributes[node.attributes[key].name.to_sym] = node.attributes[key].value
          end
        end
        if node.children.size > 0
          node.children.each do |child|
            result = xml_node_to_hash(child)

            if child.name == "text"
              unless child.next_sibling || child.previous_sibling
                return result unless attributes
                result_hash[child.name.to_sym] = result
              end
            elsif result_hash[child.name.to_sym]

              if result_hash[child.name.to_sym].is_a?(Object::Array)
                 result_hash[child.name.to_sym] << result
              else
                 result_hash[child.name.to_sym] = [result_hash[child.name.to_sym]] << result
              end
            else
              result_hash[child.name.to_sym] = result
            end
          end
          if attributes
             #add code to remove non-data attributes e.g. xml schema, namespace here
             #if there is a collision then node content supersets attributes
             result_hash = attributes.merge(result_hash)
          end
          return result_hash
        else
          return attributes
        end
      else
        return node.content.to_s
      end
    end
  end
end

module VCloud
  class UnauthorizedAccess < StandardError; end
  class WrongAPIVersion < StandardError; end
  class WrongItemIDError < StandardError; end
  class InvalidStateError < StandardError; end
  class InternalServerError < StandardError; end
  class UnhandledError < StandardError; end


  # Main class to access vCloud rest APIs
  class Connection
    attr_reader :api_url, :auth_key

    ALLOCATION_MODEL = { :AllocationVApp => "pay as you go", :AllocationPool => "allocation pool", :ReservationPool => "reservation pool" }
    ENABLED_STATUS = { :true => "enabled", :false => "disabled"}

    def initialize(host, username, password, org_name, api_version)
      @host = host
      @api_url = "#{host}/api"
      @host_url = "#{host}"
      @username = username
      @password = password
      @org_name = org_name
      @api_version = (api_version || "5.1")
    end

    ##
    # Authenticate against the specified server
    def login
      params = {
        'method' => :post,
        'command' => '/sessions'
      }

      response, headers = send_request(params)

      if !headers.has_key?(:x_vcloud_authorization)
        raise "Unable to authenticate: missing x_vcloud_authorization header"
      end

      @auth_key = headers[:x_vcloud_authorization]
    end

    ##
    # Destroy the current session
    def logout
      params = {
        'method' => :delete,
        'command' => '/session'
      }

      response, headers = send_request(params)
      # reset auth key to nil
      @auth_key = nil
    end

    ##
    # Fetch existing organizations and their IDs
    def organizations
      params = {
        'method' => :get,
        'command' => '/org'
      }

      response, headers = send_request(params)
      orgs = response.css('OrgList Org')

      results = {}
      orgs.each do |org|
        orgId = org['href'].gsub("#{@api_url}/org/", "")
        params ={
          'method' => :get,
          'command' => "/org/#{orgId}"
        }
        response, headers = send_request(params)
        fullname = response.css("FullName").first
        fullname = fullname.text unless fullname.nil?
        #results[org['name']] = orgId
        results[fullname] = orgId
      end
      results
    end

    ##
    # Fetch organization name from vdc ID
    def organization_by_vdc(vdcId)
      params = {
        'method' => :get,
        'command' => "/vdc/#{vdcId}"
      }
      orgName = ''
      response, headers = send_request(params)
      response.css("Link[type='application/vnd.vmware.vcloud.org+xml']").each do |link|
        orgId = link['href'].gsub("#{@api_url}/org/", "")
        orgName = self.organizations.index(orgId)
      end
      orgName
    end

    ##
    # Fetch details about an organization:
    # - catalogs
    # - vdcs
    # - networks
    def organization(orgId)
      params = {
        'method' => :get,
        'command' => "/org/#{orgId}"
      }

      response, headers = send_request(params)
      catalogs = {}
      response.css("Link[type='application/vnd.vmware.vcloud.catalog+xml']").each do |item|
        catalogs[item['name']] = item['href'].gsub("#{@api_url}/catalog/", "")
      end

      vdcs = {}
      response.css("Link[type='application/vnd.vmware.vcloud.vdc+xml']").each do |item|
        vdcs[item['name']] = item['href'].gsub("#{@api_url}/vdc/", "")
      end
      vdcs
    end

    ##
    # Fetch existing vdcs and their IDs
    def vdcs
      organizations = self.organizations
      vdcs = {}
      organizations.each do |key,value|
        params ={
          'method' => :get,
          'command' => "/org/#{value}"
        }

        response, headers = send_request(params)
        response.css("Link[type='application/vnd.vmware.vcloud.vdc+xml']").each do |item|
          vdcs[item['name']] = item['href'].gsub("#{@api_url}/vdc/", "")
        end

      end
      vdcs
    end

    ##
    # Fetch statistics about a given vdc:
    # - enable status
    # - description
    # - allocation model
    # - cpu units
    # - cpu allocated
    # - cpu limit
    # - cpu reserved
    # - cpu used
    # - cpu overhead
    # - memory units
    # - memory allocated
    # - memory limit
    # - memory reserved
    # - memory used
    # - memory overhead
    # - vm quota
    # - vm running
    # - vm created
    # - NIC quota
    # - Network quota
    # - Network used
    # - Storage profile
    # - Storage profile limit
    def vdc(vdcId)
      params = {
        'method' => :get,
        'command' => "/vdc/#{vdcId}"
      }
      response, headers = send_request(params)

      description = response.css("Description").first
      description = description.text unless description.nil?

      allocationmodel = response.css("AllocationModel").first
      allocationmodel = allocationmodel.text unless allocationmodel.nil?

      cpu = response.css("Cpu").first
      cpu = Hash.from_xml(cpu.to_s)
      cpu = cpu[:Cpu].downcase_key

      memory = response.css("Memory").first
      memory = Hash.from_xml(memory.to_s)
      memory = memory[:Memory].downcase_key

      nicquota = response.css("NicQuota").first
      nicquota = nicquota.text unless nicquota.nil?

      networkquota = response.css("NetworkQuota").first
      networkquota = networkquota.text unless networkquota.nil?

      usednetworkcount = response.css("UsedNetworkCount").first
      usednetworkcount = usednetworkcount.text unless usednetworkcount.nil?

      vmquota = response.css("VmQuota").first
      vmquota = vmquota.text unless vmquota.nil?

      isenabled = response.css("IsEnabled").first
      isenabled = isenabled.text unless isenabled.nil?

      runningvm = 0
      createdvms = 0
      response.css("ResourceEntity[type='application/vnd.vmware.vcloud.vApp+xml']").each do |vapp|
        vappId = vapp['href'].gsub("#{@api_url}/vApp/", "")

        params = {
          'method' => :get,
          'command' => "/vApp/#{vappId}"
        }

        subresponse, headers = send_request(params)
        subresponse.css("Vm[type='application/vnd.vmware.vcloud.vm+xml']").each do |vm|
          runningvm += 1 if vm['status'] == "4"
          createdvms += 1
        end
      end

      storage = {}
      response.css("VdcStorageProfile[type='application/vnd.vmware.vcloud.vdcStorageProfile+xml']").each do |profile|
        profileId = profile['href'].gsub("#{@api_url}/vdcStorageProfile/", "")

        params = {
          'method' => :get,
          'command' => "/vdcStorageProfile/#{profileId}"
        }

        response, headers = send_request(params)

        enabled = response.css("Enabled").first
        enabled = enabled.text unless enabled.nil?

        units = response.css("Units").first
        units = units.text unless units.nil?

        limit = response.css("Limit").first
        limit = limit.text unless limit.nil?

        default = response.css("Default").first
        default = default.text unless default.nil?

        storage = storage.merge({ [profile['name']][0] => { :enabled => enabled, :default => default, :units => units, :limit => limit } })
      end

      {
        :isenabled => ENABLED_STATUS[isenabled.to_sym],
        :description => description,
        :allocationmodel => ALLOCATION_MODEL[allocationmodel.to_sym],
        :cpu_units => cpu[:units],
        :cpu_allocated => cpu[:allocated],
        :cpu_limit => cpu[:limit],
        :cpu_reserved => cpu[:reserved],
        :cpu_used => cpu[:used],
        :cpu_overhead => cpu[:overhead],
        :memory_units => memory[:units],
        :memory_allocated => memory[:allocated],
        :memory_limit => memory[:limit],
        :memory_reserved => memory[:reserved],
        :memory_used => memory[:used],
        :memory_overhead => memory[:overhead],
        :vm_quota => vmquota,
        :vm_running =>  runningvm.to_s,
        :vm_created => createdvms.to_s,
        :network_nicquota => nicquota,
        :network_quota => networkquota,
        :network_usednetworkcount => usednetworkcount,
        :storage_profiles => storage
      }

    end

    def providervdcs_query
        params ={
          'method' => :get,
          'command' => "/query?type=providerVdc"
        }
        response, headers = send_request(params)

        response
    end

    private
      ##
      # Sends a synchronous request to the vCloud API and returns the response as parsed XML + headers.
      def send_request(params, payload=nil, content_type=nil)
        headers = {:accept => "application/*+xml;version=#{@api_version}"}
        if @auth_key
          headers.merge!({:x_vcloud_authorization => @auth_key})
        end

        if content_type
          headers.merge!({:content_type => content_type})
        end

        request = RestClient::Request.new(:method => params['method'],
                                         :user => "#{@username}@#{@org_name}",
                                         :password => @password,
                                         :headers => headers,
                                         :url => "#{@api_url}#{params['command']}",
                                         :verify_ssl => false,
                                         :payload => payload)
        begin
	  p  "(DEBUG: query) #{@api_url}#{params['command']}"
	  #p headers
	  #p payload
          response = request.execute
          if ![200, 201, 202, 204].include?(response.code)
            puts "Warning: unattended code #{response.code}"
          end

          # TODO: handle asynch properly, see TasksList
          [Nokogiri.parse(response), response.headers]
        rescue RestClient::Unauthorized => e
          raise UnauthorizedAccess, "Client not authorized. Please check your credentials."
        rescue RestClient::BadRequest => e
          body = Nokogiri.parse(e.http_body)
          message = body.css("Error").first["message"]

          case message
          when /The request has invalid accept header/
            raise WrongAPIVersion, "Invalid accept header. Please verify that the server supports v.#{@api_version} or specify a different API Version."
          when /validation error on field 'id': String value has invalid format or length/
            raise WrongItemIDError, "Invalid ID specified. Please verify that the item exists and correctly typed."
          when /The requested operation could not be executed on vApp "(.*)". Stop the vApp and try again/
            raise InvalidStateError, "Invalid request because vApp is running. Stop vApp '#{$1}' and try again."
          when /The requested operation could not be executed since vApp "(.*)" is not running/
            raise InvalidStateError, "Invalid request because vApp is stopped. Start vApp '#{$1}' and try again."
          else
            raise UnhandledError, "BadRequest - unhandled error: #{message}.\nPlease report this issue."
          end
        rescue RestClient::Forbidden => e
          body = Nokogiri.parse(e.http_body)
          message = body.css("Error").first["message"]
          raise UnauthorizedAccess, "Operation not permitted: #{message}."
        rescue RestClient::InternalServerError => e
          body = Nokogiri.parse(e.http_body)
          message = body.css("Error").first["message"]
          raise InternalServerError, "Internal Server Error: #{message}."
	rescue RestClient::NotAcceptable => e
	  body = Nokogiri.parse(e.http_body)
	  message = body.css("Error").first["message"]
	  raise InternalServerError, "NotAcceptable: #{message}." 
        end
      end

  end # class
end

# Howto use it..quiet simple
OPTIONS = {}
mandatory_options=[:url, :login, :password, :organization, :query]
optparse = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"
  opts.separator ""
  opts.separator "Options"
  opts.on("-h", "--help", "Display this help message") do
    puts opts
    exit(-1)
  end
  opts.on('-u', '--url URL', String, 'vCloud url to connect to') { |v| OPTIONS[:url] = v }
  opts.on('-l', '--login USERNAME', String, 'vCloud username') { |v| OPTIONS[:login] = v }
  opts.on('-p', '--password PASSWORD', String, 'vCloud password') { |v| OPTIONS[:password] = v }
  opts.on('-o', '--organization ORGANIZATION', String, 'vCloud organization') { |v| OPTIONS[:organization] = v }
  opts.on('-q', '--query QUERIES', String, 'Query to pass to your vCloud. List of supported queries :') { |v| OPTIONS[:query] = v }
  QUERIES.each do |query|
    opts.separator "\t\t\t\t\t #{query}"
  end
  opts.on('-i', '--items ITEMs', String, 'Comma separated list of items to query on vCloud') { |v| OPTIONS[:items] = v }

  opts.separator ""
end

# Show usage when no args pass
if ARGV.empty?
  puts optparse
  exit(-1)
end

# Validate that mandatory parameters are specified
begin
  optparse.parse!(ARGV)
  missing = mandatory_options.select{|p| OPTIONS[p].nil? }
  if not missing.empty?
    puts "Missing options: #{missing.join(', ')}"
    puts optparse
    exit(-1)
  end
  rescue OptionParser::ParseError,OptionParser::InvalidArgument,OptionParser::InvalidOption
       puts $!.to_s
       exit(-1)
end

if QUERIES.include? OPTIONS[:query]

  # connect to vCloud api
	session = VCloud::Connection.new(OPTIONS[:url], OPTIONS[:login], OPTIONS[:password], OPTIONS[:organization], '5.1')
  session.login


  case OPTIONS[:query]

  # produce discovery on organization or vdc
  when /(organization|vdc)s.discovery/
    type = OPTIONS[:query].split(/\./)

    if type[0] == "vdcs"
      query = session.vdcs
      puts JSON.pretty_generate(query)

    else
      query = session.organizations
    end

    # begin json document
    puts "{  \"data\":["

    x = 0
    query.each do |key,value|
      x += 1
      if x < query.count
        puts "{ \"{#ID}\":\"#{value}\", \"{##{type[0].upcase.chop}}\":\"#{key}\"},"
      else
        puts "{ \"{#ID}\":\"#{value}\", \"{##{type[0].upcase.chop}}\":\"#{key}\"}"
      end
    end

    # end json document
    puts "] }"

  # get organization associated to a vdc
  when "vdc.organization"
    puts session.organization_by_vdc(OPTIONS[:items]) unless OPTIONS[:items].nil?

  when /vdc.(isenabled|description|allocationmodel|cpu_units|cpu_allocated|cpu_limit|cpu_reserved|cpu_used|cpu_overhead|memory_units|memory_allocated|memory_limit|memory_reserved|memory_used|memory_overhead|vm_quota|vm_running|vm_created|network_nicquota|network_quota|network_usednetworkcount)/
    type = OPTIONS[:query].split(/\./)
    query = session.vdc(OPTIONS[:items]) unless OPTIONS[:items].nil?
    puts query[type[1].to_sym]

  when "vdc.storage_profiles"
    storage_profiles = Hash.new
    vdcs = session.vdcs
    vdcs.each do |key,value|
      query = session.vdc(value)
      storage_profiles[value] = query[:storage_profiles]
    end

    # begin json document
    puts "{  \"data\":["

    x = 0
    storage_profiles.each do |key,value|
      value.each do |k,v|
        x += 1
        if x < (value.count * storage_profiles.count)
          puts "{ \"{#ID}\":\"#{x}\", \"{#VCDID}\":\"#{key}\",\"{#VCDNAME}\":\"#{vdcs.index(key)}\",\"{#STORAGEPROFILE}\":\"#{k}\"},"
        else
          puts "{ \"{#ID}\":\"#{x}\", \"{#VCDID}\":\"#{key}\",\"{#VCDNAME}\":\"#{vdcs.index(key)}\",\"{#STORAGEPROFILE}\":\"#{k}\"}"
        end
      end
    end

    # end json document
    puts "] }"

  when /vdc.storage_profile_(limit|enabled|default)/
    keys = OPTIONS[:query].split(/_/)
    items = OPTIONS[:items].split(/,/)
    query = session.vdc(items[0]) unless OPTIONS[:items].nil?
    #puts JSON.pretty_generate(query)
    #p items
    puts query[:storage_profiles][items[1]][keys[2].to_sym]

  when /providervdc.query/
    puts session.providervdcs_query

  else
    puts "Query not yet implemented\n"
  end

else
  puts "Unsupported query\n"
end

exit(-1)
