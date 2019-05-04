require 'datasets'

require 'digest/md5'
require 'net/http'
require 'uri'
require 'json'

module Datasets
  Record = Struct.new(:id, :name, :values)

  # Estat module
  module Estatjp
    # configuration injection
    module Configuration
      attr_accessor :app_id

      #
      # configuration for e-Stat API
      # See detail at https://www.e-stat.go.jp/api/api-dev/how_to_use (Japanese only).
      # @example
      #  Datasets::Estat.configure do |config|
      #   # put your App ID for e-Stat app_id
      #   config.app_id = 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
      #  end
      #
      def configure
        yield self
      end
    end

    extend Configuration

    # wrapper class for e-Stat API service
    class JsonAPI < Dataset
      attr_accessor :app_id, :areas, :timetables, :schema

      def self.generate_url(base_url,
                            app_id,
                            stats_data_id,
                            area: nil, cat: nil, time: nil)
        # generates url for query
        params = {
          appId: app_id, lang: 'J',
          statsDataId: stats_data_id, # 統計表ID
          metaGetFlg: 'Y', cntGetFlg: 'N',
          sectionHeaderFlg: '1'
        }
        # cdArea: ["01105", "01106"].join(","), # 地域事項
        params['cdArea'] = area.join(',') if area.instance_of?(Array)
        # cdCat01: ["A2101", "A210101", "A210102", "A2201", "A2301", "A4101", "A4200", "A5101", "A5102"].join(","), # 分類事項
        params['cdCat01'] = cat.join(',') if cat.instance_of?(Array)
        # cdTime: ["1981100000", "1982100000" ,"1984100000"].join(","), # 時間軸事項
        params['cdTime'] = time.join(',') if time.instance_of?(Array)

        URI.parse("#{base_url}?#{URI.encode_www_form(params)}")
      end

      def self.extract_def(data, id)
        rec = data['GET_STATS_DATA']['STATISTICAL_DATA']\
        ['CLASS_INF']['CLASS_OBJ']
        rec.select { |x| x['@id'] == id }
      end

      def self.index_def(data_def)
        unless data_def.first['CLASS'].instance_of?(Array)
          # convert to array when number of element is 1
          data_def.first['CLASS'] = [data_def.first['CLASS']]
        end
        Hash[*data_def.first['CLASS'].map { |x| [x['@code'], x] }.flatten]
      end

      def self.get_values(data)
        data['GET_STATS_DATA']['STATISTICAL_DATA']['DATA_INF']['VALUE']
      end

      #
      # generate accessor instance for e-Stat API.
      # for detail spec : https://www.e-stat.go.jp/api/api-info/e-stat-manual
      # @param [String] api_version API Version (defaults to `'2.1'`)
      # @param [String] stats_data_id 統計表ID
      # @param [Array<String>] cat 分類事項 (省略時はすべて取得)
      # @param [Array<String>] area 地域事項 (省略時はすべて取得)
      # @param [Array<String>] time 時間軸事項 (省略時はすべて取得)
      # @param [Array<Number>] skip_level 省略する階層レベル (defaults to `[1]`)
      # @param [Boolean] skip_parent_area 末端のみの階層に限定する
      # @param [Boolean] skip_child_area 末端の階層を省略する
      # @param [Boolean] skip_nil_column 1行でも欠損がある列をスキップする
      # @param [Boolean] skip_nil_row 1列でも欠損がある行をスキップする
      # @example
      #   estat = Datasets::Estatjp::JsonAPI.new(
      #     "0000020201", # Ａ　人口・世帯
      #     cat: ["A1101"], # A1101_人口総数
      #     area: ["01105", "01106"], # "北海道 札幌市 豊平区", "北海道 札幌市 南区"
      #     time: ["1981100000", "1982100000"],
      #     skip_parent_area:false , # 例: 札幌市○○区があるときは札幌市をスキップ
      #     skip_child_area: true, # 例: 札幌市○○区をスキップして札幌市を残す TODO skip_(parent|child) を統合する
      #     skip_nil_column: true, #  1行でも欠損があったら列をスキップする
      #     skip_nil_row: false, # 1列でも欠損があったら行をスキップする
      #   )
      #
      def initialize( stats_data_id,
                      api_version: '2.1',
                      area: nil, cat: nil, time: nil,
                      skip_level: [1],
                      skip_parent_area: true,
                      skip_child_area: false,
                      skip_nil_column: true,
                      skip_nil_row: false,
                      time_range: nil)
        @app_id = Estatjp.app_id
        if @app_id.nil? || @app_id.empty?
          raise ArgumentError, 'Please set app_id via `Datasets::Estat.configure` method'
        end

        super()

        @base_url = "http://api.e-stat.go.jp/rest/#{api_version}/app/json/getStatsData"
        @api_version = api_version
        @metadata.id = "estat-api-#{api_version}"
        @metadata.name = "e-Stat API #{api_version}"
        @metadata.url = @base_url
        @metadata.description = "e-Stat API #{api_version}"

        @stats_data_id = stats_data_id
        @area = area
        @cat = cat
        @time = time
        @skip_level = skip_level
        @skip_child_area = skip_child_area
        @skip_parent_area = skip_parent_area
        @skip_nil_column = skip_nil_column
        @skip_nil_row = skip_nil_row
        @time_range = time_range
      end

      #
      # fetch data records from Remote API
      # @example
      #   indices = []
      #   rows = []
      #   map_id_name = {}
      #   estat.each do |record|
      #     # 北海道に限定する
      #     next unless record.id.to_s.start_with? '01'
      #     indices << record.id
      #     rows << record.values
      #     map_id_name[record.id] = record.name
      #   end
      #
      def each
        url = JsonAPI.generate_url(@base_url,
                                   @app_id,
                                   @stats_data_id,
                                   area: @area,
                                   cat: @cat,
                                   time: @time)
        json_data = fetch_data(url)
        index_data(json_data)
        return to_enum(__method__) unless block_given?

        # create rows
        @areas.each do |a_key, a_value|
          rows = []
          @timetables.reject { |_key, x| x[:skip] }.each do |st_key, _st_value|
            row = []
            @columns.reject { |_key, x| x[:skip] }.each do |c_key, _c_value|
              begin
                row << @indexed_data[st_key][a_key][c_key]
              rescue NoMethodError
                row << nil
              end
            end
            rows << row
          end
          next unless rows.count(nil).zero?

          yield(Record.new(a_key, a_value['@name'], rows.flatten))
        end
      end

      private

      def fetch_data(url)
        # download
        option_hash = Digest::MD5.hexdigest(url.to_s)
        base_name = "estat-#{option_hash}.json"
        data_path = cache_dir_path + base_name
        download(data_path, url.to_s) unless data_path.exist?

        # parse json
        json_data = File.open(data_path) do |io|
          JSON.parse(io.read)
        end
        json_data
      end

      def index_data(json_data)
        # re-index data

        # table_def = JsonAPI.extract_def(json_data, "tab")
        timetable_def = JsonAPI.extract_def(json_data, 'time')
        column_def = JsonAPI.extract_def(json_data, 'cat01')
        area_def = JsonAPI.extract_def(json_data, 'area')

        # p table_def.map { |x| x["@name"] }
        @timetables = JsonAPI.index_def(timetable_def)
        @columns = JsonAPI.index_def(column_def)
        @areas = JsonAPI.index_def(area_def)

        # apply time_range to timetables
        if @time_range.instance_of?(Range)
          @timetables.select! { |k, _v| @timetables.keys[@time_range].include? k }
        end

        @indexed_data = Hash[*@timetables.keys.map { |x| [x, {}] }.flatten]
        JsonAPI.get_values(json_data).each do |row|
          next unless @timetables.key?(row['@time'])

          oldhash = @indexed_data[row['@time']][row['@area']]
          oldhash = {} if oldhash.nil?
          newhash = oldhash.merge(row['@cat01'] => row['$'].to_f)
          @indexed_data[row['@time']][row['@area']] = newhash
        end

        skip_areas
        skip_nil_column
        @schema = create_header
      end

      def skip_areas
        # skip levels
        @areas.reject! { |_key, x| @skip_level.include? x['@level'].to_i }

        # skip area that has children
        if @skip_parent_area
          # inspect hieralchy of areas
          @areas.each do |_a_key, a_value|
            next unless @areas.key? a_value['@parentCode']

            @areas[a_value['@parentCode']][:has_children] = true
          end
          # filter areas without children
          @areas.reject! { |_key, x| x[:has_children] }
        end

        # skip child area
        if @skip_child_area
          @areas.reject! { |_a_key, a_value| (@areas.key? a_value['@parentCode']) }
        end
      end

      def skip_nil_column
        # filter timetables and columns
        if @skip_nil_column
          @areas.each do |a_key, _a_value|
            @timetables.each do |st_key, st_value|
              unless @indexed_data[st_key].key?(a_key)
                st_value[:skip] = true
                next
              end
              @columns.each do |c_key, c_value|
                # p @indexed_data[st_key][a_key][c_key] == nil
                unless @indexed_data[st_key][a_key].key?(c_key)
                  c_value[:skip] = true
                  next
                end
              end
            end
          end
        end
      end

      def create_header
        schema = []
        @timetables.reject { |_key, x| x[:skip] }.each do |_st_key, st_value|
          @columns.reject { |_key, x| x[:skip] }.each do |_c_key, c_value|
            schema << "#{st_value['@name']}_#{c_value['@name']}"
          end
        end
        schema
      end
    end
  end
end
