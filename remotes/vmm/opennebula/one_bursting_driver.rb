#!/usr/bin/env ruby 

ONE_LOCATION = ENV["ONE_LOCATION"] if !defined?(ONE_LOCATION)

if !ONE_LOCATION
    RUBY_LIB_LOCATION = "/usr/lib/one/ruby" if !defined?(RUBY_LIB_LOCATION)
    ETC_LOCATION      = "/etc/one/" if !defined?(ETC_LOCATION)
else
    RUBY_LIB_LOCATION = ONE_LOCATION + "/lib/ruby" if !defined?(RUBY_LIB_LOCATION)
    ETC_LOCATION      = ONE_LOCATION + "/etc/" if !defined?(ETC_LOCATION)
end

$: << RUBY_LIB_LOCATION

ONE_BURSTING_DRIVER_CONF = "#{ETC_LOCATION}/one_bursting_driver.conf"

require 'rubygems'
require 'yaml'
require 'CommandManager'
require 'scripts_common'
require 'rexml/document'
require 'VirtualMachineDriver'
require "xmlrpc/client"
require 'nokogiri'
require 'occi-api'
require 'uri'

class ONEBurstingDriver
    # Constructor, loads credentials and endpoint
    def initialize(hostname)
        @hostname = hostname

        public_cloud_one_conf  = YAML::load(File.read(ONE_BURSTING_DRIVER_CONF))

        @instance_types = public_cloud_one_conf['instance_types']
        @localhost = public_cloud_one_conf['localhost']
        @host = public_cloud_one_conf['host']
        @rocci_settings = public_cloud_one_conf['rocci_endpoint']
        #sanitize data
        raise "hostname not defined for #{rocci_settings}" if @rocci_settings['hostname'].nil?
        raise "type not defined for #{rocci_settings}" if @rocci_settings['type'].nil?
        raise "port not defined for #{rocci_settings}" if @rocci_settings['port'].nil?
        raise "username not defined for #{rocci_settings}" if @rocci_settings['username'].nil?
        raise "password not defined for #{rocci_settings}" if @rocci_settings['password'].nil?
        raise "hostname not defined for #{localhost}" if @localhost['hostname'].nil?
        raise "rpc_path not defined for #{localhost}" if @localhost['rpc_path'].nil?
        raise "port not defined for #{localhost}" if @localhost['port'].nil?
        raise "username not defined for #{localhost}" if @localhost['username'].nil?
        raise "password not defined for #{localhost}" if @localhost['password'].nil?
        raise "hostname not defined for #{host}" if @host['hostname'].nil?
        raise "rpc_path not defined for #{host}" if @host['rpc_path'].nil?
        raise "port not defined for #{host}" if @host['port'].nil?
        raise "username not defined for #{host}" if @host['username'].nil?
        raise "password not defined for #{host}" if @host['password'].nil?
        raise "host_mon not defined for #{host}" if @host['host_mon'].nil?

        @local_client = XMLRPC::Client.new(@localhost['hostname'], @localhost['rpc_path'], @localhost['port'])
        connection_args = {
              :host => @host['hostname'],
              :port => @host['port'],
              :use_ssl => true,
              :path => @host['rpc_path']
            }
        @client = XMLRPC::Client.new_from_hash(connection_args)
        @local_credentials = "#{@localhost['username']}:#{@localhost['password']}"
        @credentials = "#{@host['username']}:#{@host['password']}"

        @rocci_client = Occi::Api::Client::ClientHttp.new({
          :endpoint => "https://#{@rocci_settings['hostname']}:#{@rocci_settings['port']}/",
          :auth => {
            :type       => @rocci_settings['type'],
            :username   => @rocci_settings['username'],
            :password   => @rocci_settings['password']
          },
          :log => {
            :out        => STDERR,
            :level      => Occi::Api::Log::ERROR
          }
        })
    end

    #
    # Returns quotas on remote OpenNebula instance
    #

    def get_remote_quotas
        begin
            response = @client.call("one.user.info",@credentials, -1)
        rescue XMLRPC::FaultException => e
            puts "Error:"
            puts e.faultCode
            puts e.faultString
            exit -1
        end   

        doc = Nokogiri::XML.parse(response[1])

        cpu = doc.xpath("//VM_QUOTA//CPU").text
        cpu_used = doc.xpath("//VM_QUOTA//CPU_USED").text
        memory = doc.xpath("//VM_QUOTA//MEMORY").text
        memory_used = doc.xpath("//VM_QUOTA//MEMORY_USED").text

        # These could be used for fixed and instance-based monitoring modes. Leaving them for possible future usage
        
        cpu = cpu.to_i * 100
        cpu_used = cpu_used.to_i * 100
        memory = memory.to_i * 1024
        memory_used = memory_used.to_i * 1024

        quotas = "TOTALMEMORY=#{memory}\n"
        quotas << "TOTALCPU=#{cpu}\n"
        # quotas << "USEDMEMORY=0\n"
        # quotas << "USEDCPU=0\n"
        # quotas << "USEDMEMORY=#{memory_used}\n"
        # quotas << "USEDCPU=#{cpu_used}\n"
        # quotas << "FREEMEMORY=#{(memory - memory_used)}\n"
        # quotas << "FREECPU=#{cpu - cpu_used}\n"

        return quotas
    end

    def state_to_string(state)
        if state.to_i == 3
            return "a"
        else
            return "-"
        end
    end

    def get_local_id(remote_id)
        begin
            response = @local_client.call("one.vmpool.info", @local_credentials, -3, -1, -1, -1)
        rescue XMLRPC::FaultException => e
            puts "Error:"
            puts e.faultCode
            puts e.faultString
            exit -1
        end   
        doc = Nokogiri::XML.parse(response[1])
        id = doc.xpath("//VM[DEPLOY_ID='#{remote_id}']/ID").text
        if id.to_s == ''
            return -1
        else
            return id
        end 
    end

    def get_remote_id(local_id)     
        begin
            response = @local_client.call("one.vm.info", @local_credentials, local_id.to_i)
        rescue XMLRPC::FaultException => e
            puts "Error:"
            puts e.faultCode
            puts e.faultString
            exit -1
        end 

        doc = Nokogiri::XML.parse(response[1])
        return doc.xpath("//VM/DEPLOY_ID").text
    end

    def get_all_vms_poll_info
        begin
            response = @client.call("one.vmpool.info", @credentials, -3, -1, -1, -1)
        rescue XMLRPC::FaultException => e
            puts "Error:"
            puts e.faultCode
            puts e.faultString
            exit -1
        end   
        doc = Nokogiri::XML.parse(response[1])
        vms = doc.xpath("//VM//ID")
        vms_info = "VM_POLL=YES\n"
        usedcpu = 0
        usedmemory = 0
        total_cpu_used = 0
        total_memory_used = 0
        vms.each do |vm|
            state = doc.xpath("//VM[ID='#{vm.text}']/STATE").text
            if state.to_i == 3
                local_id = get_local_id(doc.xpath("//VM[ID='#{vm.text}']/ID").text)
                vms_info << "VM=[\n"
                vms_info << "  ID=#{local_id || -1},\n"
                vms_info << "  DEPLOY_ID=#{doc.xpath("//VM[ID='#{vm.text}']/DEPLOY_ID").text},\n"
                used_cpu = doc.xpath("//VM[ID='#{vm.text}']/CPU").text
                nettx = doc.xpath("//VM[ID='#{vm.text}']/NET_TX").text
                netrx = doc.xpath("//VM[ID='#{vm.text}']/NET_RX").text
                memory = doc.xpath("//VM[ID='#{vm.text}']/MEMORY").text
                name = doc.xpath("//VM[ID='#{vm.text}']/DEPLOY_ID").text
                ip = doc.xpath("//VM[ID='#{vm.text}']//TEMPLATE//NIC//IP").text
                state = state_to_string(state)
                poll_string = "USEDCPU=#{used_cpu.to_f} NETTX=#{nettx} NETRX=#{netrx} NAME=#{name} USEDMEMORY=#{memory} STATE=#{state} GUEST_IP=#{ip}"
                vms_info << "  POLL=\"#{poll_string}\" ]\n"
                total_cpu_used += used_cpu.to_f
                total_memory_used += memory.to_i
            end
        end
        consumption = "USEDMEMORY=#{total_memory_used}\n"
        consumption << "USEDCPU=#{total_cpu_used}\n"
        return consumption << vms_info
    end

    #
    # Get the info of all hosts and remote instances.
    # 
    def monitor_hosts_and_vms
        totalmemory = 0
        totalcpu = 0

        host_info =  "HYPERVISOR=opennebula\n"
        host_info << "PUBLIC_CLOUD=YES\n"
        host_info << "PRIORITY=-1\n"
        host_info << "CPUSPEED=1000\n"
        host_info << "HOSTNAME=\"#{@host['hostname']}\"\n" 

        case @host['host_mon']['type']
        when 'fixed'
            host_info << "TOTALMEMORY=#{@host['host_mon']['memory']}\n"
            host_info << "TOTALCPU=#{@host['host_mon']['cpu']}\n"
        when 'instance_based'
            @host['capacity'].each { |name, size|
                cpu, mem = instance_type_capacity(name)

                totalmemory += mem * size.to_i
                totalcpu    += cpu * size.to_i
            }
            host_info << "TOTALMEMORY=#{totalmemory.round}\n"
            host_info << "TOTALCPU=#{totalcpu}\n"
        when 'dynamic'
            host_info << get_remote_quotas
        end

        usedcpu    = 0
        usedmemory = 0
        
        vms_info = get_all_vms_poll_info

        puts host_info
        puts vms_info
    end

    #
    # Left from EC2 driver, would be used for instance-based monitoring
    #
    def instance_type_capacity(name)
        return 0, 0 if @instance_types[name].nil?
        return @instance_types[name]['cpu'].to_i * 100 ,
               @instance_types[name]['memory'].to_i * 1024
    end

    def poll(local_id)
        deploy_id = get_remote_id(local_id)

        begin
            response = @client.call("one.vm.info", @credentials, deploy_id.to_i)
        rescue XMLRPC::FaultException => e
            puts "Error:"
            puts e.faultCode
            puts e.faultString
            exit -1
        end   

        doc = Nokogiri::XML.parse(response[1])

        vm_info = "VM=[\n"
        vm_info << "  ID=#{local_id},\n"
        vm_info << "  DEPLOY_ID=#{deploy_id},\n"
        used_cpu = doc.xpath("//VM/CPU").text
        nettx = doc.xpath("//VM/NET_TX").text
        netrx = doc.xpath("//VM/NET_RX").text
        memory = doc.xpath("//VM/MEMORY").text
        name = doc.xpath("//VM/DEPLOY_ID").text
        state = state_to_string(doc.xpath("//VM/STATE").text)
        ip = doc.xpath("//VM//TEMPLATE//NIC//IP").text
        poll_string = "USEDCPU=#{used_cpu.to_f} NETTX=#{nettx} NETRX=#{netrx} NAME=#{name} USEDMEMORY=#{memory} STATE=#{state} GUEST_IP=#{ip}"
        vm_info << "  POLL=\"#{poll_string}\" ]\n"

        return vm_info
    end

    #
    # VM-management actions
    #
    
    def deploy(deploy_id, host, xml_text)
        id = get_remote_id(deploy_id)
        if id != ""
            restore(deploy_id)
        else
            doc = Nokogiri::XML.parse(xml_text)

            cmpt = @rocci_client.get_resource "compute"
            cmpt.mixins << @rocci_client.get_mixin(doc.xpath("//VM/USER_TEMPLATE/PUBLIC_CLOUD/PROVIDER_TEMPLATE_ID").text, "os_tpl")
            # cmpt.mixins << @rocci_client.get_mixin(doc.xpath("//VM/USER_TEMPLATE/PUBLIC_CLOUD/SIZE").text, "resource_tpl")
            cmpt.title = doc.xpath("//VM/NAME").text

            cmpt_loc = @rocci_client.create cmpt
            puts(URI(cmpt_loc).path.split('/').last)
        end
    end

    def cancel(deploy_id)
        id = get_remote_id(deploy_id)
        @rocci_client.delete "https://#{@rocci_settings['hostname']}:#{@rocci_settings['port']}/compute/#{id}"
    end

    def reboot(deploy_id)
        id = get_remote_id(deploy_id)
        startaction = Occi::Core::Action.new scheme='http://schemas.ogf.org/occi/infrastructure/compute/action#', term='restart', title='restart compute instance'
        startactioninstance = Occi::Core::ActionInstance.new startaction, nil
        @rocci_client.trigger "https://#{@rocci_settings['hostname']}:#{@rocci_settings['port']}/compute/#{id}", startactioninstance
    end

    def shutdown(deploy_id)
       # cancel(deploy_id)
        id = get_remote_id(deploy_id)
        startaction = Occi::Core::Action.new scheme='http://schemas.ogf.org/occi/infrastructure/compute/action#', term='stop', title='stop compute instance'
        startactioninstance = Occi::Core::ActionInstance.new startaction, nil
        @rocci_client.trigger "https://#{@rocci_settings['hostname']}:#{@rocci_settings['port']}/compute/#{id}", startactioninstance 
    end

    def save(deploy_id)
        id = get_remote_id(deploy_id)
        startaction = Occi::Core::Action.new scheme='http://schemas.ogf.org/occi/infrastructure/compute/action#', term='stop', title='stop compute instance'
        startactioninstance = Occi::Core::ActionInstance.new startaction, nil
        @rocci_client.trigger "https://#{@rocci_settings['hostname']}:#{@rocci_settings['port']}/compute/#{id}", startactioninstance      
    end

    def restore(deploy_id)
        id = get_remote_id(deploy_id)
        startaction = Occi::Core::Action.new scheme='http://schemas.ogf.org/occi/infrastructure/compute/action#', term='start', title='restart compute instance'
        startactioninstance = Occi::Core::ActionInstance.new startaction, nil
        @rocci_client.trigger "https://#{@rocci_settings['hostname']}:#{@rocci_settings['port']}/compute/#{id}", startactioninstance
    end
end