# AD-1 E6 DenseIO test deployment — 1 node to validate the OKE+NVMe path
# and probe host capacity through the node pool.
node_shape      = "VM.DenseIO.E6.Ax.Flex"
node_ocpus      = 8
node_memory_gbs = 96
node_count      = 1
