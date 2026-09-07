#!/usr/bin/env ruby

require "aws-sdk-s3"

endpoint = ARGV.fetch(0)
region = ARGV.fetch(1)
access_key = ENV.fetch("ZIGFS_COMPAT_ACCESS_KEY")
secret_key = ENV.fetch("ZIGFS_COMPAT_SECRET_KEY")
session_token = ENV["ZIGFS_COMPAT_SESSION_TOKEN"]
session_token = nil if session_token.nil? || session_token.empty?

credentials = Aws::Credentials.new(access_key, secret_key, session_token)
client = Aws::S3::Client.new(
  endpoint: endpoint,
  region: region,
  force_path_style: true,
  credentials: credentials,
  retry_limit: 0,
)

bucket = "zigfs-p9-sdk-#{Process.pid}-#{Time.now.to_i}"
source_key = "fixtures/sdk.txt"
copy_key = "copies/sdk.txt"
source = "ZigFS independent AWS SDK fixture\n"

begin
  client.create_bucket(bucket: bucket)
  client.put_object(bucket: bucket, key: source_key, body: source, content_type: "text/plain")

  head = client.head_object(bucket: bucket, key: source_key)
  abort "HeadObject returned #{head.content_length} bytes" unless head.content_length == source.bytesize

  downloaded = client.get_object(bucket: bucket, key: source_key).body.read
  abort "GetObject content mismatch" unless downloaded == source

  client.copy_object(bucket: bucket, key: copy_key, copy_source: "#{bucket}/#{source_key}")
  copied = client.get_object(bucket: bucket, key: copy_key).body.read
  abort "CopyObject content mismatch" unless copied == source

  client.delete_object(bucket: bucket, key: source_key)
  client.delete_object(bucket: bucket, key: copy_key)
ensure
  begin
    client.delete_object(bucket: bucket, key: source_key)
    client.delete_object(bucket: bucket, key: copy_key)
    client.delete_bucket(bucket: bucket)
  rescue StandardError
    # The runner reports the original failure; cleanup is best effort.
  end
end

puts "AWS SDK Ruby probe: PASS"
