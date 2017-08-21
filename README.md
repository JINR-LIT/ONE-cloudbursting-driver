# ONE-cloudbursting-driver

This driver enables OpenNebula-based cloud to "burst" Virtual Machines (VM) to external OpenNebula clouds using built-in OpenNebula XML-RPC and OCCI interfaces.

As an example let's assume you have an OpenNebula cloud (to which we will refer as "<b>one-owned</b>") and two other external clouds also based on OpenNebula: <b>one-ext-1</b> and <b>one-ext-2</b>).

## Prerequisites

1. [OCCI-Cli](https://github.com/gwdg/rOCCI-cli) must be installed on one-owned
2. Both, one-ext-1 and one-ext-2, must provide occi-interface. On how to set it up on one-ext consult [rOCCI-server](https://github.com/gwdg/rOCCI-server#development) github repository.

## Installation

To install the driver run `install.sh`. This script just copies all the necessary files to proper locations and sets file permissions.

## Configuration

First, add the following to the `/etc/one/oned.conf` and restart oned service:
```
IM_MAD = [
     name       = "im_opennebula",
     executable = "one_im_sh",
     arguments  = "-t 1 -r 0 opennebula" ]

VM_MAD = [
  name       = "vmm_opennebula",
  executable = "one_vmm_sh",
  arguments  = "-t 15 -r 0 opennebula",
  type       = "xml" ]
```

Add the external clouds by editting the file `/etc/one/one_bursting_driver.conf`. The driver supports bursting to multiple external clouds at the same time each having its own section starting with the cloud name. Following is the example of configuration for two clouds, one-ext-1 and one-ext-2:
```
ONE-EXT-1:
    rocci_endpoint:
        hostname: one-ext-1.example.com
        port: 11443
        type: basic
        username: occiuser
        password: occipass
    localhost:
        hostname: localhost
        rpc_path: /RPC2
        port: 2633
        username: oneadmin
        password: pass
    host:
        hostname: one-ext-1.example.com
        rpc_path: /RPC2
        port: 11366
        username: occiuser
        password: occipass
        host_mon:
            type: dynamic
ONE-EXT-2:
    rocci_endpoint:
        hostname: one-ext-2.example.com
        port: 1701
        type: basic
        username: occiuser2
        password: pass
    localhost:
        hostname: localhost
        rpc_path: /RPC2
        port: 2633
        username: oneadmin
        password: pass
    host:
        hostname: one-ext-2.example.com
        rpc_path: /RPC2
        port: 1476
        username: occiuser2
        password: pass
        host_mon:
            type: dynamic
```
<b>Note:</b> There is no need to restart any services after any changes in this file - it is dynamically reloaded on each driver operation.

<b>ONE-EXT-1</b> and <b>ONE-EXT-2</b> are section names and can be any strings.
<b>rocci_endpoint</b> and <b>host</b> are OCCI and XML-RPC of the external clouds (one-ext-1 and one-ext-2 in our case), and the localhost is the XML-RPC of the owned cloud (one-owned).
* <b>rocci_endpoint</b> is used to perform VM life-cycle operations (creating, rebooting, deleting).
* <b>host</b> is used for collecting VMs monitoring information and getting quotas from external OpenNebula-based clouds.
* <b>localhost</b> is used for getting the IDs of local VMs to convert them into IDs of corresponding VMs in the external cloud.

<b>Note:</b> make sure that all external ports are not blocked by the firewalls.

Next, add the external clouds as hosts into one-owned cloud, for example with CLI:
```
onehost create ONE-EXT-1 --im im_opennebula --vm vmm_opennebula --net dummy
onehost create ONE-EXT-2 --im im_opennebula --vm vmm_opennebula --net dummy
```

## Usage

In your one-owned cloud prepare a VM template as usual adding a PUBLIC_CLOUD section to it:
```
PUBLIC_CLOUD=[
    PROVIDER_TEMPLATE_ID="uuid_example_template",
    TYPE="opennebula"
]
```

In case PROVIDER_TEMPLATE_IDs have different names in different external clouds, then also add a SCHED_REQUIREMENTS parameter to specify the particular cloud you want to run this template on.

To test OCCI connection and to get the list of available resources you can use the following simple script:
```
#!/usr/bin/env ruby

require 'rubygems'
require 'net/http'
require 'occi-api'
require 'pp'
require 'openssl'

OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

client = Occi::Api::Client::ClientHttp.new({
  :endpoint => "https://hostname:11443/",
  :auth => {
    :type               => "basic",
    :username          => "name",
    :password => "pass" },
  :log => {
    :out   => STDERR,
    :level => Occi::Api::Log::ERROR
  }
})

puts "\n\nListing all available mixins:"
client.list_mixins.each do |mixin|
  puts "\n#{mixin}"
end
```

In case of using https connection comment/Uncomment the line `OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE` to test if there is some problem with the certificate.
