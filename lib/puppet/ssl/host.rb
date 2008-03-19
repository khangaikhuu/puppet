require 'puppet/ssl'
require 'puppet/ssl/key'
require 'puppet/ssl/certificate'
require 'puppet/ssl/certificate_request'
require 'puppet/util/constant_inflector'

# The class that manages all aspects of our SSL certificates --
# private keys, public keys, requests, etc.
class Puppet::SSL::Host
    # Yay, ruby's strange constant lookups.
    Key = Puppet::SSL::Key
    CertificateRequest = Puppet::SSL::CertificateRequest
    Certificate = Puppet::SSL::Certificate

    extend Puppet::Util::ConstantInflector

    attr_reader :name
    attr_accessor :ca

    # A bit of metaprogramming that we use to define all of
    # the methods for managing our ssl-related files.
    def self.manage_file(name, &block)
        var = "@%s" % name

        maker = "generate_%s" % name
        reader = "read_%s" % name

        classname = file2constant(name.to_s)

        begin
            klass = const_get(classname)
        rescue
            raise Puppet::DevError, "Cannot map %s to a valid constant" % name
        end

        # Define the method that creates it.
        define_method(maker, &block)

        # Define the reading method.
        define_method(reader) do
            klass.find(self.name)
        end

        # Define the overall method, which just calls the reader and maker
        # as appropriate.
        define_method(name) do
            unless cert = instance_variable_get(var)
                return nil unless cert = send(reader)
                instance_variable_set(var, cert)
            end
            cert.content
        end
    end

    # This is the private key; we can create it from scratch
    # with no inputs.
    manage_file :key do
        @key = Key.new(name)
        @key.generate
        @key.save
        true
    end

    # Our certificate request requires the key but that's all.
    manage_file :certificate_request do
        generate_key unless key
        @certificate_request = CertificateRequest.new(name)
        @certificate_request.generate(key)
        @certificate_request.save
        return true
    end

    # Our certificate itself might not successfully "generate", since
    # that generation is actually accomplished by a CA signing the
    # stored CSR.
    manage_file :certificate do
        generate_certificate_request unless certificate_request

        @certificate = Certificate.new(name)
        if @certificate.generate(certificate_request)
            @certificate.save
            return true
        else
            return false
        end
    end

    # Is this a ca host, meaning that all of its files go in the CA collections?
    def ca?
        ca
    end

    # Remove all traces of this ssl host
    def destroy
        [key, certificate, certificate_request].each do |instance|
            instance.class.destroy(instance) if instance
        end
    end

    def initialize(name)
        @name = name
        @key = @certificate = @certificate_request = nil
        @ca = false
    end

    # Extract the public key from the private key.
    def public_key
        key.public_key
    end
end