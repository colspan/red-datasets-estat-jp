# frozen_string_literal: true

require 'pathname'

RSpec.describe Datasets::Estatjp do
  it 'has a version number' do
    expect(Datasets::Estatjp::VERSION).not_to be nil
  end

  it 'raises api APPID is unset' do
    # error if app_id is undefined
    expect do
      Datasets::Estatjp::JSONAPI.new('test')
    end.to raise_error(ArgumentError)
  end

  it 'is ok when APPID is set' do
    # ok if app_id is set by ENV
    ENV['ESTATJP_APPID'] = 'test_by_env'
    expect do
      obj = Datasets::Estatjp::JSONAPI.new('test')
      expect(obj.app_id).to eq 'test_by_env'
    end.not_to raise_error
    ENV['ESTATJP_APPID'] = nil

    # ok if app_id is set by configure method
    Datasets::Estatjp.configure do |config|
      config.app_id = 'test_by_method'
    end
    expect do
      obj = Datasets::Estatjp::JSONAPI.new('test')
      expect(obj.app_id).to eq 'test_by_method'
    end.not_to raise_error
    Datasets::Estatjp.app_id = nil

    # ok if app_id is set by ENV
    ENV['ESTATJP_APPID'] = 'test_by_env2'
    expect do
      obj = Datasets::Estatjp::JSONAPI.new('test')
      expect(obj.app_id).to eq 'test_by_env2'
    end.not_to raise_error
    ENV['ESTATJP_APPID'] = nil
  end

  it 'generates url correctly' do
    app_id = 'abcdef'
    stats_data_id = '000000'
    base_url = 'http://testurl/rest/2.1/app/json/getStatsData'
    url = Datasets::Estatjp::JSONAPI.generate_url(base_url, app_id, stats_data_id)
    expect(url.to_s).to eq 'http://testurl/rest/2.1/app/json/getStatsData?appId=abcdef&lang=J&statsDataId=000000&metaGetFlg=Y&cntGetFlg=N&sectionHeaderFlg=1'
  end

  it 'raises when status is invalid' do
    ENV['ESTATJP_APPID'] = 'test_appid_invalid'
    estat_obj = Datasets::Estatjp::JSONAPI.new('test')
    estat_obj.instance_eval do
      @data_path = Pathname('spec/data/test-403-forbidden.json')
    end
    expect do
      estat_obj.each do |record|
        record
      end
    end.to raise_error(Exception)
    ENV['ESTATJP_APPID'] = nil
  end

  it 'can parse api result correctly' do
    ENV['ESTATJP_APPID'] = 'test_appid_correct'
    test_path = 'spec/data/test-200-0000020201.json'

    estat_obj = Datasets::Estatjp::JSONAPI.new('test')
    estat_obj.instance_eval do
      @data_path = Pathname(test_path)
    end
    expect do
      records = []
      sapporo_records = []
      estat_obj.each do |record|
        records << record
        sapporo_records << record if record.name.start_with? '北海道 札幌市'
      end
      expect(records.length).to eq 1897
      expect(sapporo_records.length).to eq 10
    end.not_to raise_error

    estat_obj = \
      Datasets::Estatjp::JSONAPI.new('test',
                                     hierarchy_selection: 'parent')
    estat_obj.instance_eval do
      @data_path = Pathname(test_path)
    end
    expect do
      records = []
      sapporo_records = []
      estat_obj.each do |record|
        records << record
        sapporo_records << record if record.name.start_with? '北海道 札幌市'
      end
      expect(records.length).to eq 1722
      expect(sapporo_records.length).to eq 1
    end.not_to raise_error

    estat_obj = \
      Datasets::Estatjp::JSONAPI.new('test',
                                     hierarchy_selection: 'both')
    estat_obj.instance_eval do
      @data_path = Pathname(test_path)
    end
    expect do
      records = []
      sapporo_records = []
      estat_obj.each do |record|
        records << record
        sapporo_records << record if record.name.start_with? '北海道 札幌市'
      end
      expect(records.length).to eq 1917
      expect(sapporo_records.length).to eq 11
    end.not_to raise_error

    # skip_nil_column: true,
    # skip_nil_row: false,

    ENV['ESTATJP_APPID'] = nil
  end
end