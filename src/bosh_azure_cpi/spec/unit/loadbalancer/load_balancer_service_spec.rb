# frozen_string_literal: true

require 'spec_helper'
require 'cloud/azure/loadbalancer/load_balancer_service'

describe Bosh::AzureCloud::LoadBalancerService do
  let(:azure_client) { instance_double(Bosh::AzureCloud::AzureClient) }
  let(:config) do
    double('load balancer config', name: 'test-lb', resource_group_name: 'lb-group',
                                  default_backend_pool_type: 'ip', backend_pool_name: nil, backend_pool_name_v6: nil)
  end
  let(:configs) { [config] }
  let(:vm_properties) { double('VM properties', resource_group_name: 'vm-group', load_balancers: configs) }
  let(:service) { described_class.new(azure_client) }
  let(:load_balancer) do
    {
      name: 'test-lb',
      backend_address_pools: [
        { name: 'empty' },
        { name: 'nic', backend_ip_configurations: [{ 'id' => 'nic-member' }],
                       load_balancer_backend_addresses: [{ 'name' => 'ip-member' }] },
        { name: 'ip', load_balancer_backend_addresses: [{ 'name' => 'ip-member' }] }
      ]
    }
  end

  before do
    allow(azure_client).to receive(:get_load_balancer_by_name).with('lb-group', 'test-lb').and_return(load_balancer)
  end

  it 'keeps the retrieval helpers private' do
    expect(service).not_to respond_to(:get_by_name)
    expect(service).not_to respond_to(:_get_load_balancers)
    expect(described_class.private_instance_methods).to include(:get_by_name, :_get_load_balancers, :_detect_backend_pool_type)
  end

  describe '#add_vm' do
    it 'refreshes and updates each load balancer using its own name and resource group' do
      configured_load_balancers = %w[first second].map do |name|
        {
          name: "#{name}-lb",
          resource_group_name: "#{name}-group",
          backend_address_pools: [{ name: 'pool', backend_address_pools_type: 'ip' }]
        }
      end
      network_interfaces = [{
        primary: true,
        ip_configurations: [{ private_ip: '10.0.0.5', private_ip_address_version: 'IPv4',
                              subnet: { id: '/vnets/test/subnets/default' } }]
      }]
      allow(SecureRandom).to receive(:uuid).and_return('address-name')
      expect(service).to receive(:flock)
        .with("#{Bosh::AzureCloud::Helpers::CPI_LOCK_LOAD_BALANCER}-all", File::LOCK_EX)
        .twice.and_yield

      configured_load_balancers.each do |load_balancer|
        expect(azure_client).to receive(:get_load_balancer_by_name)
          .with(load_balancer[:resource_group_name], load_balancer[:name])
          .and_return(backend_address_pools: [{ name: 'pool', load_balancer_backend_addresses: [] }])
        expect(azure_client).to receive(:update_load_balancer_backend_pool)
          .with(load_balancer[:resource_group_name], load_balancer[:name], 'pool', [
            { name: 'address-name', properties: { ipAddress: '10.0.0.5', virtualNetwork: { id: '/vnets/test' } } }
          ])
      end

      service.add_vm(configured_load_balancers, network_interfaces)
    end
  end

  describe '#list_all_load_balancers' do
    it 'returns all load balancers from the client without changing them' do
      load_balancers = [{ name: 'first-lb' }, { name: 'second-lb' }]
      expect(azure_client).to receive(:list_all_load_balancers).with(no_args).and_return(load_balancers)

      expect(service.list_all_load_balancers).to equal(load_balancers)
    end

    it 'preserves an empty client result' do
      expect(azure_client).to receive(:list_all_load_balancers).and_return([])

      expect(service.list_all_load_balancers).to eq([])
    end

    it 'preserves a nil client result' do
      expect(azure_client).to receive(:list_all_load_balancers).and_return(nil)

      expect(service.list_all_load_balancers).to be_nil
    end
  end

  describe '#load_balancers' do
    it 'configures all pools using membership and the default type' do
      expect(service.load_balancers(vm_properties)).to eq([load_balancer])
      expect(load_balancer[:resource_group_name]).to eq('lb-group')
      expect(load_balancer[:backend_address_pools].map { |pool| pool[:backend_address_pools_type] }).to eq(%w[ip nic ip])
      expect(load_balancer).not_to have_key(:backend_address_pools_v6)
    end

    it 'classifies NIC-only membership without relying on the configured default' do
      load_balancer[:backend_address_pools][1].delete(:load_balancer_backend_addresses)

      expect(service.load_balancers(vm_properties).first[:backend_address_pools][1][:backend_address_pools_type]).to eq('nic')
    end

    it 'classifies a single backend pool returned as a hash' do
      load_balancer[:backend_address_pools] = load_balancer[:backend_address_pools].first
      allow(config).to receive(:backend_pool_name).and_return('EMPTY')

      expect(service.load_balancers(vm_properties).first[:backend_address_pools]).to eq([
        { name: 'empty', backend_address_pools_type: 'ip' }
      ])
    end

    it 'uses the VM resource group when no load balancer resource group is configured' do
      allow(config).to receive(:resource_group_name).and_return(nil)
      expect(azure_client).to receive(:get_load_balancer_by_name).with(nil, 'test-lb').and_return(load_balancer)

      expect(service.load_balancers(vm_properties).first[:resource_group_name]).to eq('vm-group')
    end

    it 'selects IPv4 and IPv6 pools case-insensitively from the complete pool list' do
      allow(config).to receive(:backend_pool_name).and_return('NIC')
      allow(config).to receive(:backend_pool_name_v6).and_return('IP')

      result = service.load_balancers(vm_properties).first

      expect(result[:backend_address_pools].map { |pool| pool[:name] }).to eq(['nic'])
      expect(result[:backend_address_pools_v6].map { |pool| pool[:name] }).to eq(['ip'])
      expect(result[:backend_address_pools].first[:backend_address_pools_type]).to eq('nic')
      expect(result[:backend_address_pools_v6].first[:backend_address_pools_type]).to eq('ip')
    end

    it 'uses a NIC default for empty pools when configured' do
      allow(config).to receive(:default_backend_pool_type).and_return('nic')

      expect(service.load_balancers(vm_properties).first[:backend_address_pools].map { |pool| pool[:backend_address_pools_type] }).to eq(%w[nic nic ip])
    end

    it 'raises when the load balancer is missing' do
      allow(azure_client).to receive(:get_load_balancer_by_name).and_return(nil)

      expect { service.load_balancers(vm_properties) }.to raise_error(Bosh::Clouds::CloudError, "Cannot find the load balancer 'test-lb'")
    end

    it 'raises when the configured IPv4 pool is missing' do
      allow(config).to receive(:backend_pool_name).and_return('missing-v4')

      expect { service.load_balancers(vm_properties) }.to raise_error(Bosh::Clouds::CloudError, /backend_pool named 'missing-v4'/)
    end

    it 'raises when the configured IPv6 pool is missing' do
      allow(config).to receive(:backend_pool_name_v6).and_return('missing-v6')

      expect { service.load_balancers(vm_properties) }.to raise_error(Bosh::Clouds::CloudError, /backend_pool named 'missing-v6'/)
    end

    it 'uses the properties supplied to each call' do
      expect(service.load_balancers(vm_properties)).to eq([load_balancer])

      other_properties = double('other VM properties', load_balancers: [])
      expect(service.load_balancers(other_properties)).to eq([])
    end

    it 'accepts nil VM properties without fetching load balancers' do
      expect(azure_client).not_to receive(:get_load_balancer_by_name)

      expect(service.load_balancers(nil)).to be_nil
    end

    context 'without configs' do
      let(:configs) { nil }

      it 'returns nil without fetching load balancers' do
        expect(azure_client).not_to receive(:get_load_balancer_by_name)
        expect(service.load_balancers(vm_properties)).to be_nil
      end
    end

    context 'with empty configs' do
      let(:configs) { [] }

      it 'returns an empty array without fetching load balancers' do
        expect(azure_client).not_to receive(:get_load_balancer_by_name)
        expect(service.load_balancers(vm_properties)).to eq([])
      end
    end
  end
end
