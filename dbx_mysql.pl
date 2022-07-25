%dbx = (
	epoch_to_timestamp_fn => 'FROM_UNIXTIME',

	to_hex_string => sub {
		my ($bin) = @_;
		return "X'" . unpack("H*", $bin) . "'";
	},

	column_info_type_col => 'mysql_type_name',

	tables => {
		"report" => {
			column_definitions 		=> [
				"serial"		, "int"			, "unsigned NOT NULL AUTO_INCREMENT",
				"mindate"		, "timestamp"		, "NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP",
				"maxdate"		, "timestamp"		, "NULL",
				"domain"		, "varchar(255)"	, "NOT NULL",
				"org"			, "varchar(255)"	, "NOT NULL",
				"reportid"		, "varchar(255)"	, "NOT NULL",
				"email"			, "varchar(255)"	, "NULL",
				"extra_contact_info"	, "varchar(255)"	, "NULL",
				"policy_adkim"		, "varchar(20)"		, "NULL",
				"policy_aspf"		, "varchar(20)"		, "NULL",
				"policy_p"		, "varchar(20)"		, "NULL",
				"policy_sp"		, "varchar(20)"		, "NULL",
				"policy_pct"		, "tinyint"		, "unsigned",
				"raw_xml"		, "mediumtext"		, "",
				],
			additional_definitions 		=> "PRIMARY KEY (serial), UNIQUE KEY domain (domain, reportid)",
			table_options			=> "ROW_FORMAT=COMPRESSED",
			indexes				=> [],
			},
		"rptrecord" => {
			column_definitions 		=> [
				"id"			, "int"	, "unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY",
				"serial"		, "int"							, "unsigned NOT NULL",
				"ip"			, "int"							, "unsigned",
				"ip6"			, "binary(16)"						, "",
				"rcount"		, "int"							, "unsigned NOT NULL",
				"disposition"		, "enum('" . join("','", ALLOWED_DISPOSITION) . "')"	, "",
				"reason"		, "varchar(255)"					, "",
				"dkimdomain"		, "varchar(255)"					, "",
				"dkimresult"		, "enum('" . join("','", ALLOWED_DKIMRESULT) . "')"	, "",
				"spfdomain"		, "varchar(255)"					, "",
				"spfresult"		, "enum('" . join("','", ALLOWED_SPFRESULT) . "')"	, "",
				"spf_align"		, "enum('" . join("','", ALLOWED_SPF_ALIGN) . "')"	, "NOT NULL",
				"dkim_align"		, "enum('" . join("','", ALLOWED_DKIM_ALIGN) . "')"	, "NOT NULL",
				"identifier_hfrom"	, "varchar(255)"					, ""
				],
			additional_definitions 		=> "KEY serial (serial, ip), KEY serial6 (serial, ip6)",
			table_options			=> "",
			indexes				=> [],
			},
		"tls_report" => {
			column_definitions 		=> [
				"serial"					, "int"				, "unsigned NOT NULL AUTO_INCREMENT",
				"mindate"				, "timestamp"		, "NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP",
				"maxdate"				, "timestamp"		, "NULL",
				"domain"					, "varchar(255)"	, "NULL",
				"org"						, "varchar(255)"	, "NOT NULL",
				"reportid"				, "varchar(255)"	, "NOT NULL",
				"contact"				, "varchar(255)"	, "NULL",
				"policy_type"			, "varchar(20)"	, "NULL",
				"policy_string"		, "text"				, "NULL",
				"summary_failure"		, "int"				, "unsigned NULL",
				"summary_successful"	, "int"				, "unsigned NULL",
				"raw_json"				, "mediumtext"		, "",
				],
			additional_definitions 		=> "PRIMARY KEY (serial), UNIQUE KEY domain (domain,reportid)",
			table_options			=> "ROW_FORMAT=COMPRESSED",
			indexes				=> [],
			},
			"tls_rptrecord" => {
			column_definitions 		=> [
				"id"								, "int"					, "unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY",
				"serial"							, "int"					, "unsigned NOT NULL",
				"result_type"					, "varchar(255)"		, "",
				"sending_mta_ip"				, "int"					, "unsigned",
				"sending_mta_ip6"				, "binary(16)"			, "",
				"receiving_mx_hostname"		, "varchar(255)"		, "",
				"receiving_mx_helo"			, "varchar(255)"		, "",
				"receiving_ip"					, "int"					, "unsigned",
				"receiving_ip6"				, "binary(16)"			, "",
				"failed_session_count"		, "int"					, "unsigned NOT NULL",
				"additional_information"	, "varchar(255)"		, "",
				"failure_reason_code"		, "varchar(255)"		, "",
				],
			additional_definitions 		=> "KEY serial (serial,sending_mta_ip), KEY serial6 (serial,sending_mta_ip6)",
			table_options			=> "",
			indexes				=> [],
			},
		},

	add_column => sub {
		my ($table, $col_name, $col_type, $col_opts, $after_col) = @_;

		my $insert_pos = "FIRST";
		if ($after_col) {
			$insert_pos = "AFTER $after_col";
		}
		return "ALTER TABLE $table ADD $col_name $col_type $col_opts $insert_pos;"
	},

	modify_column => sub {
		my ($table, $col_name, $col_type, $col_opts) = @_;
		return "ALTER TABLE $table MODIFY COLUMN $col_name $col_type $col_opts;"
	},
);

1;
