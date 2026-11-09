# frozen_string_literal: true

module Bosh::AzureCloud
  class LoadBalancerService
    include Helpers

    # Initializes the service with the Azure client used for load balancer operations
    # @param [Bosh::AzureCloud::AzureClient] azure_client - The Azure client
    def initialize(azure_client)
      @azure_client = azure_client
      @logger = Bosh::Clouds::Config.logger
    end

    # Retrieves configured load balancers, classifies their pools, and selects named IPv4 and IPv6 pools
    # @param [Object, nil] vm_properties - VM properties containing load balancer configurations and the resource group
    # @return [Array<Hash>, nil] - The configured load balancers, or nil when no configurations are provided
    def load_balancers(vm_properties)
      _get_load_balancers(vm_properties)
    end

    # Lists all load balancers returned by the Azure client without changing them
    # @return [Array<Hash>, nil] - The load balancers returned by the Azure client
    def list_all_load_balancers
      _list_all_load_balancers
    end

    # Registers the primary NIC's private IP addresses in the configured IP-based backend pools
    # @param [Array<Hash>] load_balancers - one Hash (returned by Bosh::AzureCloud::AzureClient.get_load_balancer_by_name) per load balancer
    # @param [Array<Hash>] network_interfaces - The VM network interfaces, including primary status and IP configurations
    # @return [void]
    def add_vm(load_balancers, network_interfaces)
      return if load_balancers.nil? || load_balancers.empty?
      return if network_interfaces.nil? || network_interfaces.empty?

      _add_vm_to_load_balancer_backend_pool(load_balancers,network_interfaces)
    end

    # Removes matching IP and virtual network endpoints while preserving unrelated backend addresses
    # The caller must hold the global load balancer lock during cleanup.
    # @param [Array<Array<String>>] vm_ips - Pairs of private IP addresses and virtual network IDs to remove
    # @return [void]
    def remove_vm(vm_ips)
      _remove_vm_from_load_balancer_backend_pool(vm_ips)
    end

    private

    # Gets all load balancers from the Azure client
    # @return [Array<Hash>, nil] - The load balancers returned by the Azure client
    def _list_all_load_balancers
      @azure_client.list_all_load_balancers
    end

    # Gets a load balancer by its name within the specified resource group
    # @param [String, nil] resource_group_name - The resource group, or nil to use the Azure client's default
    # @param [String] name - The name of the load balancer
    # @return [Hash, nil] - The load balancer details, or nil when the load balancer is not found
    def get_by_name(resource_group_name, name)
      @azure_client.get_load_balancer_by_name(resource_group_name, name)
    end

    # Updates the backend pool of a load balancer with the specified backend addresses
    # An empty address list clears the pool when its final member is removed.
    # @param [String] resource_group_name - The name of the resource group
    # @param [String] load_balancer_name - The name of the load balancer
    # @param [String] pool_name - The name of the backend pool
    # @param [Array<Hash>] backend_addresses - The backend addresses to update
    # @return [void]
    def update_backend_pool(resource_group_name, load_balancer_name, pool_name, backend_addresses)
      @azure_client.update_load_balancer_backend_pool(
        resource_group_name,
        load_balancer_name,
        pool_name,
        backend_addresses
      )
    end

    # Finds backend pools containing the supplied endpoints and updates only pools with matching members
    # Uses the caller-held global load balancer lock for the list and update operations.
    # @param [Array<Array<String>>] vm_ips - Pairs of private IP addresses and virtual network IDs to remove
    # @return [void]
    def _remove_vm_from_load_balancer_backend_pool(vm_ips)
      load_balancers = list_all_load_balancers
      return if load_balancers.nil? || load_balancers.empty?

      #Find load balancer backend pool that has the ip addresses of the vm assigned.
      load_balancer_tu = load_balancers.find_all { |load_balancer|
        Array(load_balancer[:backend_address_pools]).any? {
          |pool| Array(pool[:load_balancer_backend_addresses]).any? {
            |backend_address| vm_ips.include?(_backend_address_endpoint(backend_address['properties'])) } }
      }

      unless load_balancer_tu.nil? || load_balancer_tu.empty?
        load_balancer_tu.each do |load_balancer|
            resource_group = load_balancer[:id].split('/resourceGroups/')[1].split('/')[0]

            load_balancer[:backend_address_pools].each do |pool|
              existing_addresses = Array(pool[:load_balancer_backend_addresses])
              next if existing_addresses.empty?

              matches_vm = existing_addresses.any? do |backend_address|
                vm_ips.include?(_backend_address_endpoint(backend_address['properties']))
              end
              next unless matches_vm

              backend_addresses_pool = {}
              backend_addresses_pool[:name] = pool[:name]
              backend_addresses_pool[:loadBalancerBackendAddresses] = []

              Array(pool[:load_balancer_backend_addresses]).each do |backend_address|
                unless vm_ips.include?(_backend_address_endpoint(backend_address['properties']))
                  poolVmName = backend_address['name']
                  backend_addresses_pool[:loadBalancerBackendAddresses] << _build_backend_address(backend_address['properties'], poolVmName)
                end
              end

              update_backend_pool(resource_group, load_balancer[:name], pool[:name], backend_addresses_pool[:loadBalancerBackendAddresses])

          end
        end
      end
    end

    # Builds a backend address, generating a UUID name when no name is supplied
    # Reuses the supplied properties and adds endpoint fields when an IP address or virtual network ID is supplied.
    # @param [Hash] properties - Backend address properties to preserve or populate
    # @param [String] backend_address_name - The address name, or an empty string to generate a UUID
    # @param [String, nil] private_ip - The private IP address to assign
    # @param [String, nil] vnet_id - The virtual network ID to assign
    # @return [Hash] - The backend address name and properties for an Azure pool update
    def _build_backend_address(properties = {}, backend_address_name = '', private_ip = nil, vnet_id = nil)
      backend_address_name = SecureRandom.uuid if backend_address_name.empty?
      backend_address = { name: backend_address_name.to_s, properties: properties }

      unless private_ip.nil? && vnet_id.nil?
        backend_address[:properties][:ipAddress] = private_ip
        backend_address[:properties][:virtualNetwork] = { id: vnet_id }
      end

      backend_address
    end

    # Extracts a private IP and virtual network ID, deriving the network ID from the subnet when necessary
    # @param [Hash] properties - Backend address properties with string or symbol keys
    # @return [Array<String>, nil] - The private IP and virtual network ID pair, or nil if either is missing
    def _backend_address_endpoint(properties)
      properties = properties.transform_keys(&:to_s)
      virtual_network = properties['virtualNetwork'] || {}
      network_id = virtual_network['id'] || virtual_network[:id]
      subnet = properties['subnet'] || {}
      subnet_id = subnet['id'] || subnet[:id]
      network_id ||= subnet_id.split('/subnets/').first unless subnet_id.nil?
      private_ip = properties['ipAddress']
      return nil if private_ip.nil? || network_id.nil?

      [private_ip, network_id]
    end

    # Refreshes and merges backend addresses under the global load balancer lock before updating each pool
    # @param [Array<Hash>] load_balancers - one Hash (returned by Bosh::AzureCloud::AzureClient.get_load_balancer_by_name) per load balancer
    # @param [Array<Hash>] vm_network_interfaces - The VM network interfaces, including primary status and IP configurations
    # @return [void]
    def _add_vm_to_load_balancer_backend_pool(load_balancers, vm_network_interfaces)
      load_balancers.each do |load_balancer|
        load_balancer_name = load_balancer[:name]
        resource_group_name = load_balancer[:resource_group_name]

        # First build the new backend addresses for the load balancer, then update the load balancer with the new backend addresses.
        backend_addresses = _calculate_backend_addresses_for_load_balancer(load_balancer,vm_network_interfaces)

        next if backend_addresses.empty?

        # First get the current backend pool of the load balancer, then update the backend pool with the new backend addresses.
        flock("#{CPI_LOCK_LOAD_BALANCER}-all", File::LOCK_EX) do
          load_balancer_current = get_by_name(resource_group_name, load_balancer_name)
          next if load_balancer_current.nil?

          load_balancer_current[:backend_address_pools].each do |pool|
            pool_name = pool[:name]
            backend_addresses_pool = backend_addresses.find { |p| p[:name].casecmp?(pool_name) }
            unless backend_addresses_pool.nil?
               new_ips = backend_addresses_pool[:loadBalancerBackendAddresses].map { |address| _backend_address_endpoint(address[:properties]) }.compact
               Array(pool[:load_balancer_backend_addresses]).each do |backend_address|
                 next if new_ips.include?(_backend_address_endpoint(backend_address['properties']))

                 backend_addresses_pool[:loadBalancerBackendAddresses] << _build_backend_address(backend_address['properties'], backend_address['name'])
               end

              update_backend_pool(resource_group_name, load_balancer_name, pool_name, backend_addresses_pool[:loadBalancerBackendAddresses])

            end
          end
        end
      end
    end

    # Builds addresses from the primary NIC for IP-based pools, using all IPv4 addresses and the first IPv6 address
    # @param [Hash] load_balancer - returned by Bosh::AzureCloud::AzureClient.get_load_balancer_by_name
    # @param [Array<Hash>] vm_network_interfaces - The VM network interfaces, including primary status and IP configurations
    # @return [Array<Hash>] - Pool names and backend address lists, excluding pools without eligible addresses
    def _calculate_backend_addresses_for_load_balancer(load_balancer, vm_network_interfaces)
      backend_addresses = []
      primary_nic = vm_network_interfaces.find { |nic| nic[:primary] }

      return backend_addresses if primary_nic.nil?

      load_balancer[:backend_address_pools].each do |pool|
        pool_type = pool[:backend_address_pools_type]
        next unless pool_type == LOAD_BALANCER_BACKEND_POOL_TYPE_IP

        backend_addresses_v4_pool = {}
        backend_addresses_v4_pool[:name] = pool[:name]
        backend_addresses_v4_pool[:loadBalancerBackendAddresses] = []

        primary_nic[:ip_configurations].each do |ip_config|
          private_ip = ip_config[:private_ip]
          next if private_ip.nil? || private_ip.empty?
          next unless ip_config[:private_ip_address_version].to_s.casecmp?(IP_VERSION_IPV4)

          subnet_id = ip_config[:subnet][:id]
          vnet_id = subnet_id.split('/subnets/')[0]

          backend_addresses_v4_pool[:loadBalancerBackendAddresses] << _build_backend_address({}, "", private_ip, vnet_id)
        end

        backend_addresses << backend_addresses_v4_pool unless backend_addresses_v4_pool[:loadBalancerBackendAddresses].empty?
      end

      unless load_balancer[:backend_address_pools_v6].nil? || load_balancer[:backend_address_pools_v6].empty?
        load_balancer[:backend_address_pools_v6].each do |pool_v6|
          pool_type_v6 = pool_v6[:backend_address_pools_type]
          next unless pool_type_v6 == LOAD_BALANCER_BACKEND_POOL_TYPE_IP

          backend_addresses_v6_pool = {}
          backend_addresses_v6_pool[:name] = pool_v6[:name]
          backend_addresses_v6_pool[:loadBalancerBackendAddresses] = []

          # Ipv6 adresse und subnet
          ip = primary_nic[:ip_configurations].find { |ip_config| ip_config[:private_ip] && !ip_config[:private_ip].empty? && ip_config[:private_ip_address_version].to_s.casecmp?(IP_VERSION_IPV6) }

          unless ip.nil?
            private_ip = ip[:private_ip]
            subnet_id = ip[:subnet][:id]
            vnet_id = subnet_id.split('/subnets/')[0]

            backend_addresses_v6_pool[:loadBalancerBackendAddresses] << _build_backend_address({}, "", private_ip, vnet_id)
          end
          backend_addresses << backend_addresses_v6_pool unless backend_addresses_v6_pool[:loadBalancerBackendAddresses].empty?
        end
      end
      backend_addresses
    end

    # Classifies pools in place using NIC membership first, IP membership second, and the configured default otherwise
    # @param [Bosh::AzureCloud::LoadBalancerConfig] load_balancer_config - The configuration providing the default pool type
    # @param [Array<Hash>] pools - The backend pools to classify
    # @return [Array<Hash>] - The pools with their backend_address_pools_type set
    def _detect_backend_pool_type(load_balancer_config, pools)
      default_backend_pool_type = load_balancer_config.default_backend_pool_type

      pools.each do |pool|
        pool[:backend_address_pools_type] = default_backend_pool_type

        has_nic_members = Array(pool[:backend_ip_configurations]).any?
        has_ip_members  = Array(pool[:load_balancer_backend_addresses]).any?

        # NIC membership wins only when NICs are actually attached.
        pool[:backend_address_pools_type] = LOAD_BALANCER_BACKEND_POOL_TYPE_NIC if has_nic_members
        pool[:backend_address_pools_type] = LOAD_BALANCER_BACKEND_POOL_TYPE_IP if has_ip_members && !has_nic_members

      end
    end

    # Retrieves configured load balancers and prepares their pool selections and resource groups
    # @param [Object, nil] vm_properties - VM properties containing load balancer configurations and the resource group
    # @return [Array<Hash>, nil] - The configured load balancers, or nil when no configurations are provided
    # @raise [Bosh::Clouds::CloudError] If a configured load balancer or named backend pool is missing
    def _get_load_balancers(vm_properties)
      configs = vm_properties&.load_balancers
      return nil if configs.nil?

      configs.map do |config|
        load_balancer = get_by_name(config.resource_group_name, config.name)
        cloud_error("Cannot find the load balancer '#{config.name}'") if load_balancer.nil?

        pools = load_balancer[:backend_address_pools]
        pools = [pools] unless pools.is_a?(Array)

        _detect_backend_pool_type(config, pools)

        load_balancer[:resource_group_name] = config.resource_group_name || vm_properties.resource_group_name

        if config.backend_pool_name
          pool = pools.find do |candidate|
            Hash(candidate)[:name].casecmp?(config.backend_pool_name)
          end
          cloud_error("'#{config.name}' does not have a backend_pool named '#{config.backend_pool_name}'") if pool.nil?

          load_balancer[:backend_address_pools] = [pool]
        end

        if config.backend_pool_name_v6
          pool_v6 = pools.find do |candidate|
            Hash(candidate)[:name].casecmp?(config.backend_pool_name_v6)
          end
          cloud_error("'#{config.name}' does not have a backend_pool named '#{config.backend_pool_name_v6}'") if pool_v6.nil?

          load_balancer[:backend_address_pools_v6] = [pool_v6]
        end

        load_balancer
      end
    end
  end
end
