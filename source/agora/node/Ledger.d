/*******************************************************************************

    Contains supporting code for tracking the current ledger.

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.node.Ledger;

import agora.common.API;
import agora.common.Block;
import agora.common.Data;
import agora.common.Hash;
import agora.common.Serializer;
import agora.common.Transaction;

import vibe.core.log;

import std.algorithm;

/// Ditto
public class Ledger
{
    /// data storage for all the blocks,
    /// currently a single contiguous region to
    /// improve locality of reference
    private Block[] ledger;

    /// pointer to the latest block
    private Block* last_block;

    /// Temporary storage where transactions are stored until blocks are created.
    private Transaction[] storage;

    /// Ctor
    public this ()
    {
        auto block = getGenesisBlock();
        this.addNewBlock(block);
    }

    /***************************************************************************

        Called when a new transaction is received.

        If the transaction is accepted it will be added to
        a new block, and the block will be added to the ledger.

        If the transaction is invalid, it's rejected and false is returned.

        Params:
            tx = the received transaction

        Returns:
            true if the transaction is valid and was added to a block

    ***************************************************************************/

    public bool acceptTransaction (Transaction tx) @trusted
    {
        if (!tx.verify(&this.findOutput))
            return false;

        this.storage ~= tx;
        if (this.storage.length >= Block.TxsInBlock)
            this.makeBlock();

        return true;
    }

    /***************************************************************************

        Create a new block out of transactions in the storage.

    ***************************************************************************/

    private void makeBlock () @trusted
    {
        auto block = makeNewBlock(*this.last_block, this.storage);
        this.storage.length = 0;
        assumeSafeAppend(this.storage);
        this.addNewBlock(block);
    }

    /***************************************************************************

        Returns:
            the highest block

    ***************************************************************************/

    public Block getLastBlock () @safe nothrow @nogc
    {
        return *this.last_block;
    }

    /***************************************************************************

        Get the array of blocks starting from the provided block height.
        The block at block_height is included in the array.

        Params:
            block_height = the starting block height to begin retrieval from
            max_blocks   = the maximum blocks to return at once

        Returns:
            the array of blocks starting from block_height,
            up to `max_blocks`

    ***************************************************************************/

    public Block[] getBlocksFrom (ulong block_height, size_t max_blocks) @safe nothrow @nogc
    {
        assert(max_blocks > 0);

        if (block_height > this.ledger.length)
            return null;

        return this.ledger[block_height .. min(block_height + max_blocks, $)];
    }

    /***************************************************************************

        Add a block to the ledger.

        If the block fails verification, it is not added to the ledger.

        Params:
            block = the block to add

    ***************************************************************************/

    public void addNewBlock (Block block) @trusted nothrow
    {
        // force nothrow, an exception will never be thrown here
        scope (failure) assert(0);

        if (!this.isValidBlock(block))
        {
            logDebug("Rejected block. %s", block);
            return;
        }

        this.ledger ~= block;
        this.last_block = &this.ledger[$ - 1];
    }

    /***************************************************************************

        Check the validity of a block.
        Currently only the height of the block is
        checked against the last block in the ledger.

        Params:
            block = the block to check

        Returns:
            true if the block is considered valid

    ***************************************************************************/

    private bool isValidBlock (Block block)
    {
        const expected_height = this.last_block !is null
            ? (this.last_block.header.height + 1)
            : 0;

        return block.header.height == expected_height;
    }

    /***************************************************************************

        Find a transaction in the ledger

        Params:
            tx_hash = the hash of transation

        Return:
            Return transaction if found. Return null otherwise.

    ***************************************************************************/

    private Output* findOutput (Hash tx_hash, size_t index) @safe
    {
        foreach (ref block; this.ledger)
        {
            foreach (ref tx; block.txs)
            {
                if (hashFull(tx) == tx_hash)
                {
                    if (index < tx.outputs.length)
                        return &tx.outputs[index];
                }
            }
        }

        return null;
    }
}

///
unittest
{
    import agora.common.crypto.Key;
    import std.digest : toHexString;

    scope ledger = new Ledger;
    assert(ledger.getLastBlock() == getGenesisBlock());

    // same key-pair as in getGenesisBlock()
    const genesis_key_pair = KeyPair.fromSeed(
        Seed.fromString("SCT4KKJNYLTQO4TVDPVJQZEONTVVW66YLRWAINWI3FZDY7U4JS4JJEI4"));

    // last transaction in the ledger
    Hash last_tx_hash = hashFull(getGenesisBlock().txs[$-1]);
    Transaction tx =
    {
        [Input(last_tx_hash, 0)],
        [Output(40_000_000, genesis_key_pair.address)]  // send to the same address
    };

    auto signature = genesis_key_pair.secret.sign(hashFull(tx)[]);
    tx.inputs[0].signature = signature;

    assert(ledger.acceptTransaction(tx));
    ledger.makeBlock();
    assert(ledger.getLastBlock().txs[$-1] == tx);

    // getLastBlock Testing serialization
    // Compare the serialization hexstring with the origin Ledger data.
    const ubyte[] data = serializeFull(ledger.getLastBlock());

    const string serializeData =
     "02A91D85E7279998D31FE887281D0031D8C19FA732DC0BAC3A323569B19A14AD4B274255397A9A56"
    ~"F14930CFAF7C7648377602EF0EF0E01821EE18F676092D060100000000000000DD9AAF1064DA6746"
    ~"2DC1CC496E0374084058403429A1F74B72663F6CCA35B80AECD85063383D372F9DBCD770EF654B96"
    ~"99F8C8801E6FD8041E9F517DF0B7CD2DE8D87AE11BDB8A861F7B0BD6EE6D7D37657FDD47CF8ED340"
    ~"CDE27387366F9A64ABC91788162EFE5B3C9DAA4104113445994C7F0497199FF442E88F78C582A2CF"
    ~"0000000066D002DC3D4F02352BF1E9478501CCF78FEA23AAFBAD4652630297C030A2F53E028BE2CD"
    ~"CEEBADCCAD09908A375495919B49F263127B9BCC06DC8519A51EF80D005A6202000000009D0238E0"
    ~"A171400BC6D68A9D9B316ACD5109649113A05C284F4296D2B30122F5";

    assert(data.toHexString() == serializeData);
}

/// getBlocksFrom tests
unittest
{
    import agora.common.crypto.Key;

    scope ledger = new Ledger;
    assert(ledger.getLastBlock() == getGenesisBlock());
    assert(ledger.ledger.length == 1);

    auto gen_key_pair = getGenesisKeyPair();
    Transaction last_tx = getGenesisBlock().txs[$-1];

    // each tx currently creates one block
    void genTransactions (size_t count)
    {
        auto txes = getChainedTransactions(last_tx, count, gen_key_pair, 1);
        txes.each!((tx)
            {
                assert(ledger.acceptTransaction(tx));
                ledger.makeBlock();
                assert(ledger.getLastBlock().txs[$-1] == tx);

            });

        last_tx = txes[$ - 1];
    }

    genTransactions(2);
    Block[] blocks = ledger.getBlocksFrom(0, 10);
    assert(blocks[0] == getGenesisBlock());
    assert(blocks[0].header.height == 0);
    assert(blocks.length == 3);  // two blocks + genesis block

    /// now generate 98 more txes (and blocks) to make it 100 + genesis block (101 total)
    genTransactions(98);

    assert(ledger.getLastBlock().header.height == 100);

    blocks = ledger.getBlocksFrom(0, 10);
    assert(blocks[0] == getGenesisBlock());
    assert(blocks[0].header.height == 0);
    assert(blocks.length == 10);

    /// lower limit
    blocks = ledger.getBlocksFrom(0, 5);
    assert(blocks[0] == getGenesisBlock());
    assert(blocks[0].header.height == 0);
    assert(blocks.length == 5);

    /// different indices
    blocks = ledger.getBlocksFrom(1, 10);
    assert(blocks[0].header.height == 1);
    assert(blocks.length == 10);

    blocks = ledger.getBlocksFrom(50, 10);
    assert(blocks[0].header.height == 50);
    assert(blocks.length == 10);

    blocks = ledger.getBlocksFrom(95, 10);  // only 6 left from here (block 100 included)
    assert(blocks[0].header.height == 95);
    assert(blocks.length == 6);

    blocks = ledger.getBlocksFrom(99, 10);  // only 2 left from here (ditto)
    assert(blocks[0].header.height == 99);
    assert(blocks.length == 2);

    blocks = ledger.getBlocksFrom(100, 10);  // only 1 block available
    assert(blocks[0].header.height == 100);
    assert(blocks.length == 1);

    // over the limit => return up to the highest block
    assert(ledger.getBlocksFrom(0, 1000).length == 101);

    // higher index than available => return nothing
    assert(ledger.getBlocksFrom(1000, 10).length == 0);
}
