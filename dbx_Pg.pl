%dbx = (
	epoch_to_timestamp_fn => 'TO_TIMESTAMP',

	to_hex_string => sub {
		my ($bin) = @_;
		return "'\\x" . unpack("H*", $bin) . "'";
	},

	column_info_type_col => 'pg_type',

	tables => {
		"report" => {
			column_definitions 		=> [
				"serial"		, "bigint"			, "GENERATED ALWAYS AS IDENTITY",
				"mindate"		, "timestamp without time zone"	, "NOT NULL",
				"maxdate"		, "timestamp without time zone"	, "NULL",
				"domain"		, "character varying(255)"	, "NOT NULL",
				"org"			, "character varying(255)"	, "NOT NULL",
				"reportid"		, "character varying(255)"	, "NOT NULL",
				"email"			, "character varying(255)"	, "NULL",
				"extra_contact_info"	, "character varying(255)"	, "NULL",
				"policy_adkim"		, "character varying(20)"	, "NULL",
				"policy_aspf"		, "character varying(20)"	, "NULL",
				"policy_p"		, "character varying(20)"	, "NULL",
				"policy_sp"		, "character varying(20)"	, "NULL",
				"policy_pct"		, "smallint"			, "",
				"raw_xml"		, "text"			, "",
				],
			additional_definitions 		=> "PRIMARY KEY (serial)",
			table_options			=> "",
			indexes				=> [
				"CREATE UNIQUE INDEX report_uidx_domain ON report (domain, org, reportid);"
				],
			},
		"rptrecord" => {
			column_definitions 		=> [
				"id"			, "bigint"						, "GENERATED ALWAYS AS IDENTITY",
				"serial"		, "bigint"						, "NOT NULL",
				"ip"			, "bigint"						, "",
				"ip6"			, "bytea"						, "",
				"rcount"		, "integer"						, "NOT NULL",
				"disposition"		, "character varying(20)"				, "",
				"reason"		, "character varying(255)"				, "",
				"dkimdomain"		, "character varying(255)"				, "",
				"dkimresult"		, "character varying(20)"				, "",
				"spfdomain"		, "character varying(255)"				, "",
				"spfresult"		, "character varying(20)"				, "",
				"spf_align"		, "character varying(20)"				, "NOT NULL",
				"dkim_align"		, "character varying(20)"				, "NOT NULL",
				"identifier_hfrom"	, "character varying(255)"				, ""
				],
			additional_definitions 		=> "PRIMARY KEY (id)",
			table_options			=> "",
			indexes				=> [
				"CREATE INDEX rptrecord_idx_serial ON rptrecord (serial, ip);",
				"CREATE INDEX rptrecord_idx_serial6 ON rptrecord (serial, ip6);",
				],
			},
		},

	add_column => sub {
		my ($table, $col_name, $col_type, $col_opts, $after_col) = @_;

		# Postgres only allows adding columns at the end, so $after_col is ignored
		return "ALTER TABLE $table ADD COLUMN $col_name $col_type $col_opts;"
	},

	modify_column => sub {
		my ($table, $col_name, $col_type, $col_opts) = @_;
		return "ALTER TABLE $table ALTER COLUMN $col_name TYPE $col_type;"
	},
);

1;
