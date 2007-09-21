# An actual indirection.
class Puppet::Indirector::Indirection
    @@indirections = []

    # Clear all cached termini from all indirections.
    def self.clear_cache
        @@indirections.each { |ind| ind.clear_cache }
    end
    
    attr_accessor :name, :termini

    # Clear our cached list of termini.
    # This is only used for testing.
    def clear_cache
        @termini.clear
    end

    # This is only used for testing.
    def delete
        @@indirections.delete(self) if @@indirections.include?(self)
    end

    def initialize(name, options = {})
        @name = name
        options.each do |name, value|
            begin
                send(name.to_s + "=", value)
            rescue NoMethodError
                raise ArgumentError, "%s is not a valid Indirection parameter" % name
            end
        end
        @termini = {}
        raise(ArgumentError, "Indirection %s is already defined" % @name) if @@indirections.find { |i| i.name == @name }
        @@indirections << self
    end

    # Return the singleton terminus for this indirection.
    def terminus(terminus_name = nil)
        # Get the name of the terminus.
        unless terminus_name
            param_name = "%s_terminus" % self.name
            if Puppet.config.valid?(param_name)
                terminus_name = Puppet.config[param_name]
            else
                terminus_name = Puppet[:default_terminus]
            end
            unless terminus_name and terminus_name.to_s != ""
                raise ArgumentError, "Invalid terminus name %s" % terminus_name.inspect
            end
            terminus_name = terminus_name.intern if terminus_name.is_a?(String)
        end
        
        return @termini[terminus_name] ||= make_terminus(terminus_name)
    end

    def find(*args)
        terminus.find(*args)
    end

    def destroy(*args)
        terminus.destroy(*args)
    end

    def search(*args)
        terminus.search(*args)
    end

    # these become instance methods 
    def save(*args)
        terminus.save(*args)
    end

    private

    # Create a new terminus instance.
    def make_terminus(name)
        # Load our terminus class.
        unless klass = Puppet::Indirector.terminus(self.name, name)
            raise ArgumentError, "Could not find terminus %s for indirection %s" % [name, self.name]
        end
        return klass.new
    end
end