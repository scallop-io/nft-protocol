/// Module of `Factory` type
module ob_launchpad_v2::factory {
    use std::vector;

    use sui::math;
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::bcs::{Self, BCS};
    use sui::table_vec::{Self, TableVec};
    use sui::vec_map;

    use nft_protocol::mint_pass::{Self, MintPass};
    use nft_protocol::mint_cap::{MintCap};
    use ob_utils::sized_vec;
    use ob_launchpad_v2::certificate::{Self, NftCertificate};

    /// `Warehouse` does not have NFT at specified index
    ///
    /// Call `Warehouse::redeem_nft_at_index` with an index that exists.
    const EINDEX_OUT_OF_BOUNDS: u64 = 1;
    const EINVALID_CERTIFICATE: u64 = 2;

    struct Witness has drop {}

    /// `Factory` is an inventory that can mint loose NFTs
    ///
    /// Each `Factory` may only mint NFTs from a single collection.
    struct Factory<phantom T> has key, store {
        /// `Factory` ID
        id: UID,
        // TODO: To convert to table vec, need to add fetch_idx helper
        metadata: TableVec<vector<BCS>>,
        /// `LooseMintCap` responsible for generating `PointerDomain` and
        /// maintianing supply invariants on `Collection` and `Archetype`
        /// levels.
        total_deposited: u64,
        mint_cap: MintCap<T>,
    }

    /// Creates a new `Factory`
    ///
    /// `Factory` supply is limited by both the supply of the `Collection`
    /// and `Archetype` if either is regulated.
    ///
    /// #### Panics
    ///
    /// - Archetype `RegistryDomain` is not registered
    /// - `Archetype` does not exist
    public fun new<T>(
        mint_cap: MintCap<T>,
        ctx: &mut TxContext,
    ): Factory<T> {
        Factory {
            id: object::new(ctx),
            metadata: table_vec::empty(ctx),
            total_deposited: 0,
            mint_cap,
        }
    }

    /// Deposits NFT to `Warehouse`
    ///
    /// Endpoint is unprotected and relies on safely obtaining a mutable
    /// reference to `Warehouse`.
    public fun deposit_metadata<T: key + store>(
        warehouse: &mut Factory<T>,
        metadata: vector<vector<u8>>,
    ) {
        let i = vector::length(&metadata);
        let metadata_bcs = vector::empty();

        // TODO: Test that the order is preserved
        while (i > 0) {
            vector::push_back(
                &mut metadata_bcs,
                bcs::new(vector::pop_back(&mut metadata)),
            );
        };

        vector::reverse(&mut metadata_bcs);

        table_vec::push_back(&mut warehouse.metadata, metadata_bcs);
        warehouse.total_deposited = warehouse.total_deposited + 1;
    }

    /// Mints NFT from `Factory`
    ///
    /// Endpoint is unprotected and relies on safely obtaining a mutable
    /// reference to `Factory`.
    ///
    /// #### Panics
    ///
    /// Panics if supply was exceeded.
    public fun redeem_nfts<T: key + store>(
        factory: &mut Factory<T>,
        certificate: &mut NftCertificate,
        ctx: &mut TxContext,
    ): vector<MintPass<T>> {
        certificate::assert_cert_buyer(certificate, ctx);

        let factory_id = object::id(factory);

        let nft_map = certificate::get_nft_map_mut_as_inventory(Witness {}, certificate);

        let nft_idxs = vec_map::get_mut(nft_map, &factory_id);
        let i = sized_vec::length(nft_idxs);

        assert!(i > 0, EINVALID_CERTIFICATE);

        let passes = vector::empty();

        while (i > 0) {
            let rel_index = sized_vec::remove(nft_idxs, i);

            let index = math::divide_and_round_up(
                (factory.total_deposited - 1) * rel_index,
                10_000
            );

            let mint_pass = redeem_mint_pass_<T>(factory, index, ctx);
            vector::push_back(&mut passes, mint_pass);

            i = i - 1;
        };

        let quantity = certificate::quantity_mut(Witness {}, certificate);
        *quantity = *quantity - i;
        passes
    }

    /// Mints NFT from `Factory`
    ///
    /// Endpoint is unprotected and relies on safely obtaining a mutable
    /// reference to `Factory`.
    ///
    /// #### Panics
    ///
    /// Panics if supply was exceeded.
    public fun redeem_nft<T: key + store>(
        factory: &mut Factory<T>,
        certificate: &mut NftCertificate,
        ctx: &mut TxContext,
    ): MintPass<T> {
        certificate::assert_cert_buyer(certificate, ctx);

        let factory_id = object::id(factory);
        let nft_map = certificate::get_nft_map_mut_as_inventory(Witness {}, certificate);
        let nft_idxs = vec_map::get_mut(nft_map, &factory_id);

        let rel_index = sized_vec::pop_back(nft_idxs);

        let index = math::divide_and_round_up(
            factory.total_deposited * rel_index,
            10_000
        );

        let mint_pass = redeem_mint_pass_<T>(factory, index, ctx);

        let quantity = certificate::quantity_mut(Witness {}, certificate);
        *quantity = *quantity - 1;

        mint_pass
    }

    /// Redeems NFT from specific index in `Warehouse`
    ///
    /// Does not retain original order of NFTs in the bookkeeping vector.
    ///
    /// Endpoint is unprotected and relies on safely obtaining a mutable
    /// reference to `Warehouse`.
    ///
    /// `Warehouse` may not change the logical owner of an `Nft` when
    /// redeeming as this would allow royalties to be trivially bypassed.
    ///
    /// #### Panics
    ///
    /// Panics if index does not exist in `Warehouse`.
    fun redeem_mint_pass_<T: key + store>(
        factory: &mut Factory<T>,
        index: u64,
        ctx: &mut TxContext,
    ): MintPass<T> {
        assert!(index < table_vec::length(&factory.metadata), EINDEX_OUT_OF_BOUNDS);

        let metadata = *table_vec::borrow(&factory.metadata, index);

        mint_pass::new_with_metadata(
            &mut factory.mint_cap,
            1, // SUPPLY
            &bcs::to_bytes(&metadata),
            ctx,
        )
    }
}
