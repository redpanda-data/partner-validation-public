# Partner NVMe run — spec-exact brokers: 6× DenseIO.E4.Flex8
# E4 DenseIO fixed configs: 8 OCPU MUST be 128GB + 1× 6.8TB NVMe
# (valid combos: 8/128/1, 16/256/2, 32/512/4)
node_shape      = "VM.DenseIO.E4.Flex"
node_ocpus      = 8
node_memory_gbs = 128
node_count      = 6
