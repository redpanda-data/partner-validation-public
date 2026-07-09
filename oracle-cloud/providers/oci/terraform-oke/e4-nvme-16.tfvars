# Partner Flex16 fleet — 6× DenseIO.E4.Flex 16 OCPU (32 vCPU) / 256 GB
# E4 DenseIO fixed config 16/256/2: TWO 6.8 TB NVMe devices per node
# (tune-workers.sh builds RAID-0 across them -> ~13.6 TB XFS per broker).
# NIC: 16 Gbps (2x the Flex8 fleet) — the config for the 3 GB/s load point
# and the partner's 19x Flex16 production model validation.
node_shape      = "VM.DenseIO.E4.Flex"
node_ocpus      = 16
node_memory_gbs = 256
node_count      = 6
