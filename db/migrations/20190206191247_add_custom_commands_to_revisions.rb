Sequel.migration do
  change do
    alter_table(:revisions) do
      add_column :encrypted_commands_by_process_type, String, size: 16_000
    end
  end
end
