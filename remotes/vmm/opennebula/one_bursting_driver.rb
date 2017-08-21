#!/usr/bin/env ruby

ONE_LOCATION = ENV["ONE_LOCATION"] unless defined?(ONE_LOCATION)

if !ONE_LOCATION
    RUBY_LIB_LOCATION = "/usr/lib/one/ruby" unless defined?(RUBY_LIB_LOCATION)
    ETC_LOCATION = "/etc/one/" unless defined?(ETC_LOCATION)
else
    RUBY_LIB_LOCATION = ONE_LOCATION + "/lib/ruby" unless defined?(RUBY_LIB_LOCATION)
    ETC_LOCATION = ONE_LOCATION + "/etc/" unless defined?(ETC_LOCATION)
end

$: << RUBY_LIB_LOCATION
ONE_BURSTING_DRIVER_CONF = "#{ETC_LOCATION}/one_bursting_driver.conf"

VM_STATE = { runn: 'a', poff: 'p', fail: 'e', susp: 'd', default: '-' }


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

#OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

class ONEBurstingDriver
	# Constructor, loads credentials and endpoint
    def initialize(hostname)
        @hostname = hostname

        public_cloud_one_conf  = YAML::load(File.read(ONE_BURSTING_DRIVER_CONF))

        @instance_types = public_cloud_one_conf[hostname]['instance_types']
        @localhost = public_cloud_one_conf[hostname]['localhost']
        @host = public_cloud_one_conf[hostname]['host']
        @rocci_settings = public_cloud_one_conf[hostname]['rocci_endpoint']
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
            :password   => @rocci_settings['password'],
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
            xmlrpc_fault_exception
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
    end

    def state_to_string(state)
        case state.to_i
            when 3
              VM_STATE[:runn]
            when 5
              VM_STATE[:poff]
            when 7
              VM_STATE[:fail]
            when 8
              VM_STATE[:susp]
            else
              VM_STATE[:default]
        end
    end

    def get_local_id(remote_id)
        begin
            response = @local_client.call("one.vmpool.info", @local_credentials, -3, -1, -1, -1)
            xmlrpc_fault_exception
        end
        doc = Nokogiri::XML.parse(response[1])
        id = doc.xpath("//VM[DEPLOY_ID='#{remote_id}']/ID").text
        id.to_s.empty? ? -1 : id
    end

    def get_remote_id(local_id)
        begin
            response = @local_client.call("one.vm.info", @local_credentials, local_id.to_i)
            xmlrpc_fault_exception
        end

        doc = Nokogiri::XML.parse(response[1])
        doc.xpath("//VM/DEPLOY_ID").text
    end

    def get_all_vms_poll_info
        begin
            response = @client.call("one.vmpool.info", @credentials, -3, -1, -1, -1)
            xmlrpc_fault_exception
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

            if vm_deployed?(doc, vm)
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
        consumption << vms_info
    end

    def vm_deployed?(doc, vm)
        doc.xpath("//VM[ID='#{vm.text}']/DEPLOY_ID").text != ''
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
            xmlrpc_fault_exception
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

            pre_deployment_check(doc)

            cmpt = @rocci_client.get_resource "compute"
	          cmpt.mixins << @rocci_client.get_mixin(doc.xpath("//VM/USER_TEMPLATE/PUBLIC_CLOUD/PROVIDER_TEMPLATE_ID").text, "os_tpl")
            #cmpt.mixins << @rocci_client.get_mixin(doc.xpath("//VM/USER_TEMPLATE/PUBLIC_CLOUD/SIZE").text, "resource_tpl")
            cmpt.title = doc.xpath("//VM/NAME").text
            cmpt_loc = @rocci_client.create cmpt
            puts(URI(cmpt_loc).path.split('/').last)
        end
    end

    def cancel(deploy_id)
        @rocci_client.delete "/compute/#{deploy_id}"
    end

    def reboot(deploy_id)
        startaction = Occi::Core::Action.new scheme='http://schemas.ogf.org/occi/infrastructure/compute/action#',
                                             term='restart', title='restart compute instance'
        startactioninstance = Occi::Core::ActionInstance.new startaction, nil
	      @rocci_client.trigger "/compute/#{deploy_id}", startactioninstance
    end

    def shutdown(deploy_id)
        startaction = Occi::Core::Action.new scheme='http://schemas.ogf.org/occi/infrastructure/compute/action#',
                                             term='stop', title='stop compute instance'
        startactioninstance = Occi::Core::ActionInstance.new startaction, nil
        @rocci_client.trigger "/compute/#{deploy_id}", startactioninstance
    end

    def save(deploy_id)
        startaction = Occi::Core::Action.new scheme='http://schemas.ogf.org/occi/infrastructure/compute/action#',
                                             term='stop', title='stop compute instance'
        startactioninstance = Occi::Core::ActionInstance.new startaction, nil
        @rocci_client.trigger "/compute/#{deploy_id}", startactioninstance
    end

    def restore(deploy_id)
        startaction = Occi::Core::Action.new scheme='http://schemas.ogf.org/occi/infrastructure/compute/action#',
                                             term='start', title='restart compute instance'
        startactioninstance = Occi::Core::ActionInstance.new startaction, nil
	      @rocci_client.trigger "/compute/#{deploy_id}", startactioninstance
    end

    def pre_deployment_check(doc)
        remote_template = doc.xpath("//VM/USER_TEMPLATE/PUBLIC_CLOUD/PROVIDER_TEMPLATE_ID").text
        find_remote_template(remote_template)

        remote_template_index = remote_template[remote_template.rindex(/_/)+1..remote_template.size-1].to_i
        template_info_doc = get_remote_template_doc(remote_template_index)
        current_user_info_doc = get_current_user_doc
        check_remote_template_user(current_user_info_doc, remote_template_index, template_info_doc)
        check_remote_template_doc(current_user_info_doc, remote_template_index, template_info_doc)

        template_info_image_id = template_info_doc.xpath("///IMAGE_ID").text.to_i
        remote_image_info_doc = get_remote_image_doc(template_info_image_id)

        remote_image_datastore_id = (remote_image_info_doc.xpath("//DATASTORE_ID").text).to_i
        remote_image_datastore_info_doc = get_remote_image_datastore_doc(remote_image_datastore_id)
        remote_image_datastore_info_tm_mad = remote_image_datastore_info_doc.xpath("//TEMPLATE/TM_MAD").text
        check_remote_image_datastore_tm_mad(remote_image_datastore_info_tm_mad)
    end

    def check_remote_image_datastore_tm_mad(remote_image_datastore_info_tm_mad)
        raise "TM_MAD on the remote image datastore must be ssh!" unless remote_image_datastore_info_tm_mad == 'ssh'
    end

    def get_remote_image_datastore_doc(remote_image_datastore_id)
        begin
            remote_image_datastore_info_result_flag = true
            remote_image_datastore_info_output_string = ''
            remote_image_datastore_info_error_code = 1
            remote_image_datastore_info = @client.call("one.datastore.info", @credentials,
                                                       remote_image_datastore_id,
                                                       remote_image_datastore_info_result_flag,
                                                       remote_image_datastore_info_output_string,
                                                       remote_image_datastore_info_error_code)
            xmlrpc_fault_exception
        end
        Nokogiri::XML.parse(remote_image_datastore_info[1])
    end

    def get_remote_image_doc(template_info_image_id)
        begin
            remote_image_info_result_flag = true
            remote_image_info_output_string = ''
            remote_image_info_error_code = 1
            remote_image_info = @client.call("one.image.info", @credentials, template_info_image_id,
                                             remote_image_info_result_flag, remote_image_info_output_string,
                                             remote_image_info_error_code)
            xmlrpc_fault_exception
        end
        Nokogiri::XML.parse(remote_image_info[1])
    end

    def find_remote_template(remote_template)
        unless @rocci_client.list_mixins.include? @rocci_client.get_mixin(remote_template, "os_tpl")
            raise "Template #{@rocci_client.get_mixin(remote_template, "os_tpl")} is not found in the external cloud! Template does not exist or remote template owner/group are incorrect"
        end
    end

    def check_remote_template_doc(current_user_info_doc, remote_template_index, template_info_doc)
        template_info_group_name = template_info_doc.xpath("//GNAME[//ID='#{remote_template_index}']").text
        current_user_info_group_name = current_user_info_doc.xpath("//GNAME").text
        raise "Invalid group name in the remote template" unless template_info_group_name == current_user_info_group_name
    end

    def check_remote_template_user(current_user_info_doc, remote_template_index, template_info_doc)
        template_info_user_name = template_info_doc.xpath("//UNAME[//ID='#{remote_template_index}']").text
        current_user_info_user_name = current_user_info_doc.xpath("//NAME").text
        raise "Invalid user name in the remote template" unless template_info_user_name == current_user_info_user_name
    end

    def get_current_user_doc
        begin
            current_user_info_result_flag = true
            current_user_info_output_string = ''
            current_user_info_error_code = 1
            current_user_info = @client.call("one.user.info", @credentials, -1, current_user_info_result_flag,
                                             current_user_info_output_string, current_user_info_error_code)
            xmlrpc_fault_exception
        end
        Nokogiri::XML.parse(current_user_info[1])
    end

    def get_remote_template_doc(remote_template_index)
        begin
            template_info_result_flag = true
            template_info_output_string = ''
            template_info_error_code = 1
            template_info = @client.call("one.template.info", @credentials, remote_template_index,
                                         true, template_info_result_flag, template_info_output_string,
                                         template_info_error_code)
            xmlrpc_fault_exception
        end
        Nokogiri::XML.parse(template_info[1])
    end

    def xmlrpc_fault_exception
    rescue XMLRPC::FaultException => e
        puts "Error:"
        puts e.faultCode
        puts e.faultString
        exit -1
    end
end
