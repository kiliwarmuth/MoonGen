-- vim:ts=4:sw=4:noexpandtab
--- How to configure RSS
local dpdk   = require "dpdk"
local memory = require "memory"
local device = require "device"
local stats  = require "stats"
local log    = require "log"
local mg     = require "moongen"

function configure(parser)
	parser:description("Generates traffic, enables RSS and measures how much traffic is received per queue")
	parser:argument("txPort", "Device to transmit from."):convert(tonumber)
	parser:argument("rxPort", "Device to receive from."):convert(tonumber)
	parser:option("-q --queues", "The number of queues to configure."):default(2):convert(tonumber)
	parser:option("-s --size", "Packet size."):default(60):convert(tonumber)
	parser:option("-f --flows", "The number of flows to generate."):default(100):convert(tonumber)
end

function master(args)
	local rxDev = device.config({port = args.rxPort, rxQueues = args.queues + 1, rssQueues = args.queues, rssBaseQueue = 1})
	local txDev = device.config({port = args.txPort})
	device.waitForLinks()
	mg.startTask("txSlave", txDev:getTxQueue(0), args.size, args.flows)
	for i = 1, args.queues do
		mg.startTask("rxSlave", rxDev:getRxQueue(i))
	end
	mg.waitForTasks()
end

function txSlave(queue, size, flows)
	local mempool = memory.createMemPool(function(buf)
		buf:getUdpPacket():fill{
			pktLength = size
		}
	end)
	local bufs = mempool:bufArray()
	local counter = 0
	local txCtr = stats:newDevTxCounter(queue, "plain")
	while mg.running() do
		bufs:alloc(size)
		for i, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			pkt.udp:setSrcPort(1000 + counter)
			counter = incAndWrap(counter, flows)
		end
		bufs:offloadUdpChecksums()
		queue:send(bufs)
		txCtr:update()
	end
	txCtr:finalize()
end

function rxSlave(queue)
	local bufs = memory.bufArray()
	ctr = stats:newPktRxCounter(queue, "plain")
	while mg.running(100) do
		local rx = queue:recv(bufs)
		for i = 1, rx do
			local buf = bufs[i]
			ctr:countPacket(buf)
		end
		ctr:update()
		bufs:free(rx)
	end
	ctr:finalize()
end

