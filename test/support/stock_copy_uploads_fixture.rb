  def copy_uploads
    puts ""
    print "copying uploads..."

    FileUtils.cp_r(File.join(@uploads_path, "."), Rails.public_path.join("uploads/default").to_s)

    columns = Upload.columns.map(&:name)
    last_id = Upload.unscoped.maximum(:id) || 1
    sql = "COPY uploads (#{columns.map { |c| "\"#{c}\"" }.join(", ")}) FROM STDIN"
    existing_ids_by_sha1 = Upload.unscoped.where.not(sha1: nil).pluck(:sha1, :id).to_h

    @raw_connection.copy_data(sql, @encoder) do
      source_raw_connection
        .exec("SELECT #{columns.map { |c| "\"#{c}\"" }.join(", ")} FROM uploads")
        .each do |row|
          if existing_id = existing_ids_by_sha1[row["sha1"]]
            @uploads[row["id"].to_i] = existing_id
            next
          end

          # make sure to get a backup with uploads then convert them to local.
          # when the backup is restored to a site with s3 uploads, it will upload the items
          # to the bucket
          rel_filename = row["url"].gsub(%r{^/uploads/[^/]+/}, "")
          # assumes if coming from amazonaws.com that we want to remove everything
          # but the text after the last `/`, which should leave us the filename
          rel_filename = rel_filename.gsub(%r{^//[^/]+\.amazonaws\.com/\S+uploads/[^/]+/}, "")
          absolute_filename = File.join(@uploads_path, rel_filename)

          old_id = row["id"]
          if old_id && last_id
            row["id"] = (last_id += 1)
            @uploads[old_id.to_i] = row["id"]
          end

          old_user_id = row["user_id"].to_i
          if old_user_id >= 1
            row["user_id"] = user_id_from_imported_id(old_user_id)
            next if row["user_id"].nil?
          end

          row["url"] = "/uploads/default/#{rel_filename}" if File.exist?(absolute_filename)
          @raw_connection.put_copy_data(row.values)
        end
    end

    @sequences[Upload.sequence_name] = last_id + 1
  end

