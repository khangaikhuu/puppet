#!/usr/bin/env ruby

Dir.chdir(File.dirname(__FILE__)) { (s = lambda { |f| File.exist?(f) ? require(f) : Dir.chdir("..") { s.call(f) } }).call("spec/spec_helper.rb") }

checksum = Puppet::Type.type(:file).attrclass(:checksum)
describe checksum do
    before do
        @resource = Puppet::Type.type(:file).new :path => "/foo/bar"
        @checksum = @resource.parameter(:checksum)
    end

    it "should be a parameter" do
        checksum.superclass.must == Puppet::Parameter
    end

    it "should use its current value when asked to sum content" do
        @checksum.value = :md5lite
        @checksum.expects(:md5lite).with("foobar").returns "yay"
        @checksum.sum("foobar")
    end

    it "should use :md5 to sum when no value is set" do
        @checksum.expects(:md5).with("foobar").returns "yay"
        @checksum.sum("foobar")
    end

    it "should return the summed contents with a checksum label" do
        sum = Digest::MD5.hexdigest("foobar")
        @resource[:checksum] = :md5
        @checksum.sum("foobar").should == "{md5}#{sum}"
    end

    it "should use :md5 as its default type" do
        @checksum.default.should == :md5
    end

    it "should use its current value when asked to sum a file's content" do
        @checksum.value = :md5lite
        @checksum.expects(:md5lite_file).with("/foo/bar").returns "yay"
        @checksum.sum_file("/foo/bar")
    end

    it "should use :md5 to sum a file when no value is set" do
        @checksum.expects(:md5_file).with("/foo/bar").returns "yay"
        @checksum.sum_file("/foo/bar")
    end

    it "should convert all sums to strings when summing files" do
        @checksum.value = :mtime
        @checksum.expects(:mtime_file).with("/foo/bar").returns Time.now
        lambda { @checksum.sum_file("/foo/bar") }.should_not raise_error
    end

    it "should return the summed contents of a file with a checksum label" do
        @resource[:checksum] = :md5
        @checksum.expects(:md5_file).returns "mysum"
        @checksum.sum_file("/foo/bar").should == "{md5}mysum"
    end
end
