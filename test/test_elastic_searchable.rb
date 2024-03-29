require File.join(File.dirname(__FILE__), 'helper')

class TestElasticSearchable < Test::Unit::TestCase
  ActiveRecord::Schema.define(:version => 1) do
    create_table :posts, :force => true do |t|
      t.column :title, :string
      t.column :body, :string
    end
    create_table :blogs, :force => true do |t|
      t.column :title, :string
      t.column :body, :string
    end
    create_table :users, :force => true do |t|
      t.column :name, :string
    end
    create_table :friends, :force => true do |t|
      t.column :name, :string
      t.column :favorite_color, :string
    end
    create_table :books, :force => true do |t|
      t.column :title, :string
    end
    create_table :max_page_size_classes, :force => true do |t|
      t.column :name, :string
    end
  end

  def setup
    delete_index
  end
  def teardown
    delete_index
  end
  class Post < ActiveRecord::Base
    elastic_searchable :index_options => { "analysis.analyzer.default.tokenizer" => 'standard', "analysis.analyzer.default.filter" => ["standard", "lowercase", 'porterStem'] }
    after_index :indexed
    after_index_on_create :indexed_on_create
    def indexed
      @indexed = true
    end
    def indexed?
      @indexed
    end
    def indexed_on_create
      @indexed_on_create = true
    end
    def indexed_on_create?
      @indexed_on_create
    end
  end
  context 'Post class with default elastic_searchable config' do
    setup do
      @clazz = Post
    end
    should 'respond to :search' do
      assert @clazz.respond_to?(:search)
    end
    should 'define elastic_options' do
      assert @clazz.elastic_options
    end
  end

  context 'ElasticSearchable.request with invalid url' do
    should 'raise error' do
      assert_raises ElasticSearchable::ElasticError do
        ElasticSearchable.request :get, '/elastic_searchable/foobar/notfound'
      end
    end
  end

  context 'Post.create_index' do
    setup do
      Post.create_index
      @status = ElasticSearchable.request :get, '/elastic_searchable/_status'
    end
    should 'have created index' do
      assert @status['ok']
    end
    should 'have used custom index_options' do
      expected = {
        "index.number_of_replicas" => "1",
        "index.number_of_shards" => "5",
        "index.analysis.analyzer.default.tokenizer" => "standard",
        "index.analysis.analyzer.default.filter.0" => "standard",
        "index.analysis.analyzer.default.filter.1" => "lowercase",
        "index.analysis.analyzer.default.filter.2" => "porterStem"
      }
      assert_equal expected, @status['indices']['elastic_searchable']['settings'], @status.inspect
    end
  end

  context 'deleting object that does not exist in search index' do
    should 'raise error' do
      assert_raises ElasticSearchable::ElasticError do
        Post.delete_id_from_index 123
      end
    end
  end

  context 'Post.create' do
    setup do
      @post = Post.create :title => 'foo', :body => "bar"
    end
    should 'have fired after_index callback' do
      assert @post.indexed?
    end
    should 'have fired after_index_on_create callback' do
      assert @post.indexed_on_create?
    end
  end

  context 'with empty index when multiple database records' do
    setup do
      Post.create_index
      @first_post = Post.create :title => 'foo', :body => "first bar"
      @second_post = Post.create :title => 'foo', :body => "second bar"
      Post.clean_index
    end
    context 'Post.reindex' do
      setup do
        Post.reindex
        Post.refresh_index
      end
      should 'have reindexed both records' do
        ElasticSearchable.request :get, "/elastic_searchable/posts/#{@first_post.id}"
        ElasticSearchable.request :get, "/elastic_searchable/posts/#{@second_post.id}"
      end
    end
  end

  context 'with index containing multiple results' do
    setup do
      Post.create_index
      @first_post = Post.create :title => 'foo', :body => "first bar"
      @second_post = Post.create :title => 'foo', :body => "second bar"
      Post.refresh_index
    end

    context 'searching for results' do
      setup do
        @results = Post.search 'first'
      end
      should 'find created object' do
        assert_contains @results, @first_post
      end
      should 'be paginated' do
        assert_equal 1, @results.current_page
        assert_equal 20, @results.per_page
        assert_nil @results.previous_page
        assert_nil @results.next_page
      end
    end

    context 'searching for second page using will_paginate params' do
      setup do
        @results = Post.search 'foo', :page => 2, :per_page => 1, :sort => 'id'
      end
      should 'not find objects from first page' do
        assert_does_not_contain @results, @first_post
      end
      should 'find second object' do
        assert_contains @results, @second_post
      end
      should 'be paginated' do
        assert_equal 2, @results.current_page
        assert_equal 1, @results.per_page
        assert_equal 1, @results.previous_page
        assert_nil @results.next_page
      end
    end

    context 'sorting search results' do
      setup do
        @results = Post.search 'foo', :sort => 'id:desc'
      end
      should 'sort results correctly' do
        assert_equal @second_post, @results.first
        assert_equal @first_post, @results.last
      end
    end

    context 'destroying one object' do
      setup do
        @first_post.destroy
        Post.refresh_index
      end
      should 'be removed from the index' do
        @request = ElasticSearchable.get "/elastic_searchable/posts/#{@first_post.id}"
        assert @request.response.is_a?(Net::HTTPNotFound), @request.inspect
      end
    end
  end


  class Blog < ActiveRecord::Base
    elastic_searchable :if => proc {|b| b.should_index? }
    def should_index?
      false
    end
  end
  context 'activerecord class with optional :if=>proc configuration' do
    context 'when creating new instance' do
      setup do
        Blog.any_instance.expects(:reindex).never
        @blog = Blog.create! :title => 'foo'
      end
      should 'not index record' do end #see expectations
      should 'not be found in elasticsearch' do
        @request = ElasticSearchable.get "/elastic_searchable/blogs/#{@blog.id}"
        assert @request.response.is_a?(Net::HTTPNotFound), @request.inspect
      end
    end
  end

  class User < ActiveRecord::Base
    elastic_searchable :mapping => {:properties => {:name => {:type => :string, :index => :not_analyzed}}}
  end
  context 'activerecord class with :mapping=>{}' do
    context 'creating index' do
      setup do
        User.create_index
        @status = ElasticSearchable.request :get, '/elastic_searchable/users/_mapping'
      end
      should 'have set mapping' do
        expected = {
          "users"=> {
            "properties"=> {
              "name"=> {"type"=>"string", "index"=>"not_analyzed"}
            }
          }
        }
        assert_equal expected, @status['elastic_searchable'], @status.inspect
      end
    end
  end

  class Friend < ActiveRecord::Base
    elastic_searchable :json => {:only => [:name]}
  end
  context 'activerecord class with optiona :json config' do
    context 'creating index' do
      setup do
        Friend.create_index
        @friend = Friend.create! :name => 'bob', :favorite_color => 'red'
        Friend.refresh_index
      end
      should 'index json with configuration' do
        @response = ElasticSearchable.request :get, "/elastic_searchable/friends/#{@friend.id}"
        expected = {
          "name" => 'bob' #favorite_color should not be indexed
        }
        assert_equal expected, @response['_source'], @response.inspect
      end
    end
  end

  context 'updating ElasticSearchable.default_index' do
    setup do
      ElasticSearchable.default_index = 'my_new_index'
    end
    teardown do
      ElasticSearchable.default_index = nil
    end
    should 'change default index' do
      assert_equal 'my_new_index', ElasticSearchable.default_index
    end
  end

  class Book < ActiveRecord::Base
    elastic_searchable :percolate => :on_percolated
    def on_percolated(percolated)
      @percolated = percolated
    end
    def percolated
      @percolated
    end
  end
  context 'Book class with percolate=true' do
    context 'with created index' do
      setup do
        Book.create_index
      end
      context "when index has configured percolation" do
        setup do
          ElasticSearchable.request :put, '/_percolator/elastic_searchable/myfilter', :body => {:query => {:query_string => {:query => 'foo' }}}.to_json
          ElasticSearchable.request :post, '/_percolator/_refresh'
        end
        context 'creating an object that matches the percolation' do
          setup do
            @book = Book.create :title => "foo"
          end
          should 'return percolated matches in the callback' do
            assert_equal ['myfilter'], @book.percolated
          end
        end
        context 'percolating a non-persisted object' do
          setup do
            @matches = Book.new(:title => 'foo').percolate
          end
          should 'return percolated matches' do
            assert_equal ['myfilter'], @matches
          end
        end
      end
    end
  end

  class MaxPageSizeClass < ActiveRecord::Base
    elastic_searchable
    def self.max_per_page
      1
    end
  end
  context 'with 2 MaxPageSizeClass instances' do
    setup do
      MaxPageSizeClass.create_index
      @first = MaxPageSizeClass.create! :name => 'foo one'
      @second = MaxPageSizeClass.create! :name => 'foo two'
      MaxPageSizeClass.refresh_index
    end
    context 'MaxPageSizeClass.search with default options' do
      setup do
        @results = MaxPageSizeClass.search 'foo'
      end
      should 'have one per page' do
        assert_equal 1, @results.per_page
      end
      should 'return one instance' do
        assert_equal 1, @results.length
      end
      should 'have second page' do
        assert_equal 2, @results.total_entries
      end
    end
  end
end

