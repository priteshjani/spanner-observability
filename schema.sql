ALTER DATABASE `finops-obs-db` SET OPTIONS (
  default_leader = 'us-east4'
);

ALTER DATABASE `finops-obs-db` SET OPTIONS (
  version_retention_period = '1h'
);

CREATE TABLE Accounts (
  account_id STRING(36) NOT NULL,
  account_name STRING(128) NOT NULL,
  region STRING(32) NOT NULL,
  balance NUMERIC NOT NULL,
  status STRING(20) NOT NULL DEFAULT ('ACTIVE'),
  updated_at TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true)
) PRIMARY KEY (account_id);

CREATE TABLE Transactions (
  account_id STRING(36) NOT NULL,
  transaction_id STRING(36) NOT NULL,
  amount NUMERIC NOT NULL,
  txn_type STRING(20) NOT NULL,
  client_region STRING(32) NOT NULL,
  observed_leader STRING(32),
  latency_ms FLOAT64,
  committed_at TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true)
) PRIMARY KEY (account_id, transaction_id),
  INTERLEAVE IN PARENT Accounts ON DELETE CASCADE;

CREATE INDEX TransactionsByCommittedAt ON Transactions(committed_at DESC);

CREATE TABLE HeartbeatLog (
  probe_id STRING(36) NOT NULL,
  probe_timestamp TIMESTAMP NOT NULL OPTIONS (allow_commit_timestamp = true),
  configured_leader STRING(32) NOT NULL,
  read_latency_ms FLOAT64 NOT NULL,
  write_latency_ms FLOAT64 NOT NULL,
  vpc_network STRING(128) NOT NULL,
  status STRING(32) NOT NULL
) PRIMARY KEY (probe_id);
