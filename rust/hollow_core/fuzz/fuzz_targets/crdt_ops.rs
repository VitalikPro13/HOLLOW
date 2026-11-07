#![no_main]
libfuzzer_sys::fuzz_target!(init: hollow_core::fuzz_entry::init(), |data: &[u8]| hollow_core::fuzz_entry::crdt_ops(data));
