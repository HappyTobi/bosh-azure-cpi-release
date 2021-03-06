# frozen_string_literal: true

module Bosh::AzureCloud
  class DynamicNetwork < Network
    include Helpers

    attr_reader :virtual_network_name, :subnet_name, :security_group, :application_security_groups, :ip_forwarding, :accelerated_networking

    # create dynamic network
    # @param [String] name Network name
    # @param [Hash] spec Raw network spec
    # {
    #   "my-dynamic-network" => {
    #     "netmask" => nil,
    #     "gateway" => nil,
    #     "dns"     => ["168.63.129.16"],
    #     "type"    => "dynamic",
    #     "cloud_properties" => {
    #       "virtual_network_name"   => "boshvnet",
    #       "subnet_name"            => "Bosh",
    #       "resource_group_name"    => "rg-name",
    #       "ip_forwarding"          => false,
    #       "accelerated_networking" => false,
    #       "security_group"         => "nsg-bosh",
    #       "application_security_groups" => []
    #     }
    #   }
    # }
    def initialize(azure_config, name, spec)
      super

      cloud_error('cloud_properties required for dynamic network') if @cloud_properties.nil?

      if @cloud_properties['virtual_network_name'].nil?
        cloud_error('virtual_network_name required for dynamic network')
      else
        @virtual_network_name = @cloud_properties['virtual_network_name']
      end

      if @cloud_properties['subnet_name'].nil?
        cloud_error('subnet_name required for dynamic network')
      else
        @subnet_name = @cloud_properties['subnet_name']
      end

      @security_group = Bosh::AzureCloud::SecurityGroup.parse_security_group(@cloud_properties['security_group'])

      @application_security_groups = @cloud_properties.fetch('application_security_groups', [])

      @ip_forwarding = @cloud_properties.fetch('ip_forwarding', false)

      @accelerated_networking = @cloud_properties.fetch('accelerated_networking', false)
    end

    def dns
      @spec['dns']
    end

    def has_default_dns?
      !@spec['default'].nil? && @spec['default'].include?('dns')
    end

    def has_default_gateway?
      !@spec['default'].nil? && @spec['default'].include?('gateway')
    end
  end
end
