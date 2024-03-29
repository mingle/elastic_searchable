require 'httparty'
require 'elastic_searchable/active_record'

module ElasticSearchable
  include HTTParty
  format :json
  base_uri 'localhost:9200'
  #debug_output

  class ElasticError < StandardError; end
  class << self
    # setup the default index to use
    # one index can hold many object 'types'
    @@default_index = nil
    def default_index=(index)
      @@default_index = index
    end
    def default_index
      @@default_index || 'elastic_searchable'
    end

    #perform a request to the elasticsearch server
    def request(method, url, options = {})
      response = self.send(method, url, options)
      #puts "elasticsearch request: #{method} #{url} #{" finished in #{response['took']}ms" if response['took']}"
      validate_response response
      response
    end

    private
    # all elasticsearch rest calls return a json response when an error occurs.  ex:
    # {error: 'an error occurred' }
    def validate_response(response)
      error = response['error'] || "Error executing request: #{response.inspect}"
      raise ElasticSearchable::ElasticError.new(error) if response['error'] || ![Net::HTTPOK, Net::HTTPCreated].include?(response.response.class)
    end
  end
end

ActiveRecord::Base.send(:include, ElasticSearchable::ActiveRecord)
