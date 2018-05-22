--- Demonstrates the basic usage of moonsniff in order to determine device induced latencies

local lm        = require "libmoon"
local device    = require "device"
local memory    = require "memory"
local ts        = require "timestamping"
local hist      = require "histogram"
local timer     = require "timer"
local log       = require "log"
local stats     = require "stats"
local barrier   = require "barrier"
local ms	= require "moonsniff-io"
local bit	= require "bit"
local dpdk	= require "dpdk"
local pcap	= require "pcap"

local ffi    = require "ffi"
local C = ffi.C

-- default values when no cli options are specified
local INPUT_PATH = "latencies.csv"
local INPUT_MODE = C.ms_text
local BITMASK = 0x0FFFFFFF

local CHAR_P = ffi.typeof("char *")
local free = C.rte_pktmbuf_free_export


-- skip the initialization of DPDK, as it is not needed for this script
dpdk.skipInit()

function configure(parser)
        parser:description("Demonstrate and test hardware latency induced by a device under test.\nThe ideal test setup is to use 2 taps, one should be connected to the ingress cable, the other one to the egress one.\n\n For more detailed information on possible setups and usage of this script have a look at moonsniff.md.")
	parser:option("-i --input", "Path to input file."):args(1)
	parser:option("-s --second-input", "Path to second input file."):args(1):target("second")
	parser:option("-o --output", "Name of the histogram which is generated"):args(1):default("hist")
	parser:option("-n --nrbuckets", "Size of a bucket for the resulting histogram"):args(1):convert(tonumber):default(1)
	parser:flag("-b --binary", "Read a file which was generated by moonsniff with the binary flag set")
        return parser:parse()
end

ffi.cdef[[
	void* malloc(size_t);
	void free(void*);

	uint32_t ms_hash(void*);
	uint32_t ms_get_identifier(void*);
]]

function master(args)
	if args.input then INPUT_PATH = args.input end
	if args.binary then INPUT_MODE = C.ms_binary end

	if string.match(args.input, ".*%.pcap") then
		matchPCAP(args)

	elseif string.match(args.input, ".*%.mscap") then
		local PRE
		local POST

		if not args.second then log:fatal("Detected .mscap file but there was no second file. Single .mscap files cannot be processed.") end

		if string.match(args.input, ".*%-pre%.mscap") and string.match(args.second, ".*%-post%.mscap") then
			PRE = args.input
			POST = args.second

		elseif string.match(args.second, ".*%-pre%.mscap") and string.match(args.input, ".*%-post%.mscap") then
			POST = args.input
			PRE = args.second
		else
			log:fatal("Could not decide which file is pre and which post. Pre should end with -pre.mscap and post with -post.mscap.")
		end

		local uint64_t = ffi.typeof("uint64_t")
		local uint64_p = ffi.typeof("uint64_t*")

		local map = C.malloc(ffi.sizeof(uint64_t) * BITMASK)
		map = ffi.cast(uint64_p, map)

		C.hs_initialize(args.nrbuckets)
		local prereader = ms:newReader(PRE)
		local postreader = ms:newReader(POST)

		local premscap = prereader:readSingle()
		local postmscap = postreader:readSingle()
		log:info("Pre identifier: " .. premscap.identification .. ", Post identifier: " .. postmscap.identification)

		-- precache used bit operation
		local band = bit.band

		local count = 0
		log:info("Prefilling Map")

		while premscap and count < (BITMASK - 100) do
			map[band(premscap.identification, BITMASK)] = premscap.timestamp
			premscap = prereader:readSingle()
			count = count + 1
		end

		log:info("Map is now hot")

		while premscap and postmscap do
			map[band(premscap.identification, BITMASK)] = premscap.timestamp
			premscap = prereader:readSingle()

			local ts = map[band(postmscap.identification, BITMASK)]
			if ts ~= 0 then
				 C.hs_update(postmscap.timestamp - ts)
			end
			postmscap = postreader:readSingle()
		end

		while postmscap do
			local ts = map[band(postmscap.identification, BITMASK)]
			if ts ~= 0 then C.hs_update(postmscap.timestamp - ts) end
			postmscap = postreader:readSingle()
		end

		log:info("Finished timestamp matching")

		prereader:close()
		postreader:close()
		C.free(map)

		C.hs_finalize()

		log:info("Mean: " .. C.hs_getMean() .. ", Variance: " .. C.hs_getVariance() .. "\n")

		log:info("Finished processing. Writing histogram ...")
		C.hs_write(args.output .. ".csv")
		C.hs_destroy()

	else
        	printStats()
	end
end

function matchPCAP(args)
	-- in case of pcap files we need DPDK functions
	dpdk.init()

	print("correct function")
	local PRE
	local POST

	if not args.second then log:fatal("Detected .pcap file but there was no second file. Single .pcap files cannot be processed.") end

	if string.match(args.input, ".*%-pre%.pcap") and string.match(args.second, ".*%-post%.pcap") then
		PRE = args.input
		POST = args.second

	elseif string.match(args.second, ".*%-pre%.pcap") and string.match(args.input, ".*%-post%.pcap") then
		POST = args.input
		PRE = args.second
	else
		log:fatal("Could not decide which file is pre and which post. Pre should end with -pre.mscap and post with -post.mscap.")
	end

	local uint64_t = ffi.typeof("uint64_t")
	local uint64_p = ffi.typeof("uint64_t*")

	local map = C.malloc(ffi.sizeof(uint64_t) * BITMASK)
	map = ffi.cast(uint64_p, map)

	C.hs_initialize(args.nrbuckets)

	print("initializing readers")
	local prereader = pcap:newReader(PRE)
	local postreader = pcap:newReader(POST)

	print("reading the first values")

	local mempool = memory.createMemPool()

--while true do
--
--	local prepcap = prereader:readSingle(mempool)
--	local postcap = postreader:readSingle(mempool)
--
--	print("reading worked")
----	log:info("Pre identifier: " .. prepcap.identification .. ", Post identifier: " .. postpcap.identification)
--
--	print("Got until here")
--
--	local hash = getIdent(prepcap)
--	local hash2 = getIdent(postcap)
--
--	pkt = prepcap:getUdpPacket()
--	pkt2 = postcap:getUdpPacket()
--	print("Transported payload: " .. pkt.payload.uint32[0])
--	print("ID field: " .. pkt.ip4:getID())
--
--	print("The timestamp is: " .. tostring(prepcap.udata64) .. " us")
--
--	print("The computed hash was: " .. hash)
--	print("----------------------END OF PACKET--------------")
--
--
--	-- rte_pktmbuf_free is available with the postfix _export
--	C.rte_pktmbuf_free_export(prepcap)
--	C.rte_pktmbuf_free_export(postcap)
--
--end
--
--
--	return 0

	local prepcap = prereader:readSingle(mempool)
	local postpcap = postreader:readSingle(mempool)

	-- precache used bit operation
	local band = bit.band

	local count = 0
	log:info("Prefilling Map")

	while prepcap and count < (BITMASK - 100) do
		map[band(getIdent(prepcap), BITMASK)] = prepcap.udata64

		-- print("Checksum in lua: " .. tostring(getIdent(prepcap)))

		-- always free buffers if they are not used any longer
		free(prepcap)

		prepcap = prereader:readSingle(mempool)
		count = count + 1
	end

	print("Iterations: " .. count)

	log:info("Map is now hot")
	count = 0

	while prepcap and postpcap do
		map[band(getIdent(prepcap), BITMASK)] = prepcap.udata64
		free(prepcap)
		prepcap = prereader:readSingle(mempool)

		local ts = map[band(getIdent(postpcap), BITMASK)]
		if ts ~= 0 then
			-- TODO: set ts to zero if successful? Could avoid false double hits
			-- mutltiply with 1000 to get results in ns
			C.hs_update((postpcap.udata64 - ts) * 1000)
		end
		free(postpcap)
		postpcap = postreader:readSingle(mempool)

		count = count + 1
	end

	print("Iterations: " .. count)
	count = 0

	while postpcap do
		local ts = map[band(getIdent(postpcap), BITMASK)]
		if ts ~= 0 then C.hs_update((postpcap.udata64 - ts) * 1000) end
		free(postpcap)
		postpcap = postreader:readSingle(mempool)

		count = count + 1
	end

	log:info("Finished timestamp matching")
	print("Iterations: " .. count)

	prereader:close()
	postreader:close()
	C.free(map)

	C.hs_finalize()

	log:info("Mean: " .. C.hs_getMean() .. ", Variance: " .. C.hs_getVariance() .. "\n")

	log:info("Finished processing. Writing histogram ...")
	C.hs_write(args.output .. ".csv")
	C.hs_destroy()
end

function getIdent(pcap)
--	local pkt_ptr = ffi.cast(CHAR_P, pcap.buf_addr)
--	pkt_ptr = pkt_ptr + pcap.data_off + 10
--	print(tostring(pkt_ptr))
--	return C.ms_hash(pkt_ptr)
--	return C.ms_hash(pcap)
	return C.ms_get_identifier(pcap)
end


function printStats()
        print()


        stats = C.ms_post_process(INPUT_PATH, INPUT_MODE)
        hits = stats.hits
        misses = stats.misses
        cold = stats.cold_misses
        invalidTS = stats.inval_ts
        print("Received: " .. hits + misses)
        print("\tHits: " .. hits)
        print("\tHits with invalid timestamps: " .. invalidTS)
        print("\tMisses: " .. misses)
        print("\tCold Misses: " .. cold)
        print("\tLoss by misses: " .. (misses/(misses + hits)) * 100 .. "%")
        print("\tTotal loss: " .. ((misses + invalidTS)/(misses + hits)) * 100 .. "%")
        print("Average Latency: " .. tostring(tonumber(stats.average_latency)/10^3) .. " us")

end
