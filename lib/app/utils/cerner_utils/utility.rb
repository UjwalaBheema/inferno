# frozen_string_literal: true

require 'yaml'
require 'json'
require_relative 'constraint'

module Inferno
  class Utility
    attr_accessor :capabilities,
                  :resource_name,
                  :parameters,
                  :constraints,
                  :happy_path,
                  :unhappy_path,
                  :parameter_groups,
                  :groups_cannot_be_set_together,
                  :cannot_be_set_together,
                  :must_be_set_together,
                  :at_least_one_must_be_set,
                  :input_json

    PAGING_PARAMS = ['-pageContext', '-pageDirection'].freeze
    DATA_JSON_FILE_PATH = './lib/app/cerner_data/data_json.json'

    def parse_capability(file_path)
      @capabilities ||= YAML.load_file(file_path)
    rescue StandardError
      puts "Could not find the #{file_path}"
    end

    def resource_name
      @resource_name ||= capabilities.dig('resource')
    end

    def build_combinations
      @at_least_one_must_be_set = Hash.new([])
      @groups_cannot_be_set_together = Hash.new([])
      @must_be_set_together = Hash.new([])
      @cannot_be_set_together = Hash.new([])

      constraints.each do |constraint|
        case constraint.type
        when 'at_least_one_must_be_set'
          @at_least_one_must_be_set[:happy] += constraint.parameters.map do |parameter|
            [parameters[parameter].dig('display')]
          end
          combinations = possible_combinations(parameter_display(parameters.keys - constraint.parameters))
          @at_least_one_must_be_set[:unhappy] += combinations
          @at_least_one_must_be_set[:happy] += parameter_display(constraint.parameters)
                                                 .product(combinations)
                                                 .map(&:flatten)
        when 'must_be_set_together'
          next if constraint.parameters.include?('page_context') || constraint.parameters.include?('page_direction')
        when 'cannot_be_set_together'
          fields_one = possible_combinations(parameter_display(constraint.parameters)).filter { |field| field.size > 1 }
          fields_two = parameter_display(parameters.keys - constraint.parameters)
          @cannot_be_set_together[:unhappy] += fields_two.flat_map do |field|
            [field].product(fields_one).map(&:flatten)
          end + fields_one
        when 'groups_cannot_be_set_together'
          groups = constraint.groups
          next if groups.empty?

          group_one = parameter_display(parameter_groups[groups[0]])
          group_two = parameter_display(parameter_groups[groups[1]])
          group_two_combinations = possible_combinations(group_two)
          @groups_cannot_be_set_together[:unhappy] += group_one.flat_map do |group|
            [group].product(group_two_combinations).map(&:flatten)
          end
        end
      end

      unhappy_fields = (groups_cannot_be_set_together[:unhappy] + at_least_one_must_be_set[:unhappy] + cannot_be_set_together[:unhappy]).map(&:sort).uniq
      @unhappy_path = field_with_request_parameters(unhappy_fields).uniq
      @happy_path = field_with_request_parameters((at_least_one_must_be_set[:happy] | cannot_be_set_together[:happy]).map(&:sort) - unhappy_fields).uniq
    end

    def process_occurrences
      parameters.each do |_key, value|
        display = value.dig('display')
        json_res = input_json(display)
        display_value = json_res.values[0]
        new_field = @happy_path.select { |h| h.keys.dig(0, 0) == display }[0].dup
        valid_values = []
        invalid_values = get_invalid_values(value, new_field)

        case value.dig('occurrence')
        when 'single'
          valid_values << display_value
          invalid_values << [display_value, display_value]
        when 'unbounded'
          valid_values << [display_value]
          valid_values << [display_value, display_value]
          valid_values << [display_value, display_value, display_value, display_value, display_value]
        when 'exactly_two'
          valid_values << [display_value, display_value]
        when 'one_to_two'
          valid_values << [display_value]
          valid_values << [display_value, display_value]
          invalid_values += [display_value, display_value, display_value, display_value]
        end

        next unless new_field

        valid_values.each do |values|
          @happy_path << build_hash(new_field, display, values)
        end

        (invalid_values || []).each do |values|
          @unhappy_path << build_hash(new_field, display, values)
        end
      end
    end

    def unsupported_format
      @happy_path << {@happy_path[0].keys[0] => @happy_path[0].values[0].merge('_format' => 'json')}
      @unhappy_path << {@happy_path[0].keys[0] => @happy_path[0].values[0].merge('_format' => 'testxml')}
    end

    def generate_testcases
      index = 0
      # happy_path.each do |fields|
      #   puts testcase(fields, index += 1, true)
      # end
      #
      # unhappy_path.each do |fields|
      #   puts testcase(fields, index += 1, false)
      # end
      {happy_path: happy_path, unhappy_path: unhappy_path}
    end

    private

    def build_hash(new_field, display, values)
      return { new_field.keys[0] => new_field.values[0].merge(display => values) } if new_field

      patient_id = input_json('patient').values[0]
      { [display] => {patient: patient_id, display => values } } if patient_id
    end

    def field_with_request_parameters(fields)
      fields.map { |field| {field => request_parameters(field)} }
    end

    def testcase(fields, index, happy_scenario)
      fields_text = fields.keys[0].join('_')

      %(test "search_by_#{fields_text}_#{index}" do
        metadata do
          id 'search_by_#{fields_text}_cerner_#{index}'
          name 'Server returns expected results from (#{resource_name}) search by #{fields_text}'
          link 'https://www.hl7.org/fhir/us/core/CapabilityStatement-us-core-server.html'
          description %(A server SHOULD support searching by #{fields_text} on the #{resource_name} resource)
          versions :r4
        end
        skip 'No #{resource_name} resources appear to be available. Please use patients with more information.' unless @resources_found
        search_params = #{fields.values[0]}
        search_params.each { |param, value| skip 'Could not resolve  in given resource' if value.nil? }
        reply = get_resource_by_params(versioned_resource_class('#{resource_name}'), search_params)
        #{happy_scenario ? "validate_search_reply(versioned_resource_class('#{resource_name}'), reply, search_params)" : 'assert_response_bad(reply)'}
      end)
    end

    def input_json(fields)
      # DATA_JSON_FILE_PATH = 'lib/app/cerner_data/data_json.json'
      data = File.read('./lib/app/cerner_data/data_json.json')
      JSON.parse(data).collect { |json| json[resource_name] }.compact[0]&.slice(*fields)
    end

    def request_parameters(fields)
      input_json(fields)
    end

    def possible_combinations(params)
      params -= PAGING_PARAMS
      res = []
      (1..params.size).each { |i| res += params.combination(i).to_a }
      res.uniq
    end

    def constraints_by(type)
      constraints.select do |constraint|
        constraint.type == type
      end.compact
    end

    def constraints(action_type = 'search')
      @constraints ||= capabilities.dig('actions', action_type, 'constraints').map do |constraint|
        Constraint.new(constraint)
      end
    end

    def parameters(action_type = 'search')
      @parameters ||= capabilities.dig('actions', action_type, 'parameters')
    end

    def parameter_groups
      @parameter_groups ||= constraints_by('parameter_group').each_with_object({}) do |input, results|
        results[input.name] = input.parameters unless input.name == 'paging_params'
      end
    end

    def parameter_display(fields)
      (fields || []).map { |field| parameters[field].dig('display') }
    end

    def get_invalid_values(value, new_field)
      display = value.dig('display')
      json_res = input_json([display])
      display_value = json_res.values[0]

      case value.dig('type')
      when 'number'
        [0, -100, 'cannot-be-string', [display_value, display_value]]
      when 'string'
        [-10, 0, 100]
      when 'date_range'
        [['ge2018', 'le2019'], ['ge2029-09-09', 'le2032-02-02'], ['ge1919-09-09', 'le1956-02-02'],
         ['ge2020-01-08T15:40:00.000Z', 'le2020-01-08T15:40:35.000Z'], ['ge2020-01', 'le2020-08']].each do |values|
          @happy_path << build_hash(new_field, display, values)
        end
        [['2020-01', '2020-07'], [display_value[0]], [display_value[1]], [display_value[0], display_value[0]],
         [display_value[0], display_value[1], display_value[0], display_value[1]], ['ge2019-02-01', 'le2019-01-01'],
         ['ge2019-02-01', 'eq2018-02-02']]
      when  'reference'
        reference_value_type = value.dig('reference_value_type')
        case reference_value_type
        when 'millennium'
          [0, -100, 'cannot-be-string']
        when 'pattern'
          [1000, ' ', '469982701-39997807-50469347-15*']
        end
      when  'id_token'
        id_value_type = value.dig('id_value_type')
        case id_value_type
        when 'millennium'
          [0, -100, 'cannot-be-string']
        when 'pattern'
          [1000, '469982701-39997807-50469347-15*']
        end
      when  'token'
        [0, -100, 'cannot-be-string']
      end
    end
  end
end
