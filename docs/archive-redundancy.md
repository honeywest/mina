# Archive Node Redundancy and Recovery

An archive process (`coda_archive`) consumes blocks from a daemon, processes it and writes to a postgres database.

<img src="res/archive1.png" alt="archive node architecture" width="400" height="200"/>

If the daemon that sends blocks to the archive process or if the archive process itself fails for some reason, there can be missing blocks in the database. To minimize this, it is possible to connect multiple daemons to the archive process and have multiple archive process write to the same database. Any block that is already in the database is ignored by the archive process.

<img src="res/archive2.png" alt="archive node architecture" width="400" height="200"/>

<img src="res/archive3.png" alt="archive node architecture" width="400" height="200"/>

However, multiple archive processes writing to a database concurrently could cause data inconsistencies (explained in https://github.com/MinaProtocol/mina/issues/7567). To avoid this, set the transaction isolation level of the archive database to `Serializable` using the following query:

    `ALTER DATABASE <DATABASE NAME> SET DEFAULT_TRANSACTION_ISOLATION TO SERIALIZABLE ;`

This should be done after creating the database as described in [https://minaprotocol.com/docs/archive-node](https://minaprotocol.com/docs/archive-node) and before connecting an archive process to it.

## Backing up block data

Despite running redundant daemons and archive process, it may happen so that some blocks are still missed in which case you may want to make use of the following features to save and restore block data

1. Upload block data to google cloud storage: To indicate a daemon to upload block data to google cloud storage, pass the flag `--upload-blocks-to-gcloud` . To successfully upload the file, daemon requires the following environment variables to be set:
    1. `GCLOUD_KEYFILE` : Key file for authentication
    2. `NETWORK_NAME`: Network name to be used in the filename
    3. `GCLOUD_BLOCK_UPLOAD_BUCKET` : Google cloud storage bucket where the files are uploaded

    The daemon generates a file for each block with the name `<network-name>-<protocol-state-hash>.json` . These are called precomputed blocks and will have all the fields of a block.

2. Save block data from logs: The daemon also logs block data if the flag `-log-precomputed-blocks` is passed. The log to look for is `Saw block with state hash $state_hash` that contains `precomputed_block` in the metadata and has the block information. This is the same information (precomputed blocks) that gets uploaded to google cloud storage.
3. Generate block data from another archive database: From a fully synced archive database, one can generate block data for each block using the `missing_subchain` tool. 

    The tool takes an `--archive-uri`, a `--end-state-hash`, and an optional --start-state-hash and writes all the blocks in the chain starting from start-state-hash and ending at end-state-hash (including start and end).
    If you provide both hashes, you get all blocks between start and end, and including the start and end. If just the end hash is provided, then it generates blocks starting with the unparented block closest to the end block, possibly the genesis block. The tool generates a file with name `<protocol-state-hash>.json` for each block. The block data in these files are called extensional blocks. Since these are generated from the database, they would have only the data stored in the archive database and would not contain any other information pertaining to a block (for example, blockchain snark)

    Currently this tool is not packaged and can only be build from source using `make missing_subchain` 

## Identifying missing blocks

The tool `missing_block_auditor.exe` can be used to determine any missing blocks in an archive database. The tool outputs a list of state hashes of all the blocks that are missing. This can be used to monitor the archive database for any missing blocks.

Currently this tool is not packaged and can only be build from source using `make missing_blocks_auditor`

## Restoring blocks

Missing blocks in an archive database can be added if there is block data (precomputed or extensional) available from the options listed in the backing-up-block-data section using the tool `mina-archive-blocks`. Can be built from source using `make archive_blocks`.

1. For precomputed blocks: (Generated from option 1 and 2)

    To import block data backed-up using option 1 and option 2 specify the `--precomputed` flag. It takes as arguments the paths of block data files that are to be imported

2. For extensional blocks: (Generated from option 3)

    To import extensional blocks generated from an archive database, specify the `--extensional` flag in the `archive_blocks` command

## Staking ledgers

Staking ledgers are used to determine slot winners for each epoch. Mina daemon stores staking ledger for the current epoch and the next epoch (after it is finalized). Whenever there is an epoch transition, the "next" staking ledger from the previous epoch is used to determine slot winners for the new epoch. The staking ledger from the previous epoch is replaced with the "next" staking ledger and a new "next" staking ledger is chosen. Since staking ledgers for older epochs are no longer accessible, users may want to still keep them around for reporting or other purposes.

Currently these ledgers can be exported using the cli command:
`coda.exe ledger export CURRENT-STAGED-LEDGER|STAKING-EPOCH-LEDGER|NEXT-EPOCH-LEDGER`

Epoch ledger transition happens once every 14 days (given slot-time = 3mins and slots-per-epoch = 7140). The window to backup a staking ledger is ~27 days considering "next" staking ledger is finalized after k blocks in the current epoch and therefore will be available for the rest of the current epoch and the entire next epoch.