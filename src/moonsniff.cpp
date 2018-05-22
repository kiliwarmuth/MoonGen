#include <cstdint>
#include <string>
#include <deque>
#include <iostream>
#include <fstream>
#include <mutex>
#include <cstring>
#include <thread>
#include <unordered_map>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_byteorder.h>

#define UINT24_MAX 16777215
#define INDEX_MASK (uint32_t) 0x00FFFFFF

namespace moonsniff {

	struct ms_timestamps {
		uint64_t pre;
		uint64_t post;
	};

	class Writer {
		protected:
			std::ofstream file;
		public:
			virtual void write_to_file(uint64_t old_ts, uint64_t new_ts) = 0;
			void finish(){
				file.close();
			}
			void check_stream(const char* fileName){
				if( file.fail() ){
					std::cerr << "Failed to open file < " << fileName << " >\nMake sure this file exists.\n\n";
					exit(EXIT_FAILURE);
				}
			}

	};

	class Text_Writer: public Writer {
		public:
			void write_to_file(uint64_t old_ts, uint64_t new_ts){
				file << old_ts << " " << new_ts << "\n";
			}

			Text_Writer(const char* fileName){
				file.open(fileName);
				check_stream(fileName);
			}
	};

	class Binary_Writer: public Writer {
		public:
			void write_to_file(uint64_t old_ts, uint64_t new_ts){
				file.write(reinterpret_cast<const char*>(&old_ts), sizeof(uint64_t));
				file.write(reinterpret_cast<const char*>(&new_ts), sizeof(uint64_t));
			}

			Binary_Writer(const char* fileName){
				file.open(fileName, std::ios::binary);
				check_stream(fileName);
			}
	};

	class Reader {
		protected:
			std::ifstream file;
			ms_timestamps ts;
		public:
			virtual ms_timestamps read_from_file() = 0;
			virtual bool has_next() = 0;
			void finish(){
				file.close();
			}
			void check_stream(const char* fileName){
				if( file.fail() ){
					std::cerr << "Failed to open file < " << fileName << " >\nMake sure this file exists.\n\n";
					exit(EXIT_FAILURE);
				}
			}
	};

	class Text_Reader: public Reader {
		public:
			bool has_next(){
				return file >> ts.pre >> ts.post ? true : false;
			}
			
			ms_timestamps read_from_file(){
				return ts;
			}

			Text_Reader(const char* fileName){
				file.open(fileName);
				check_stream(fileName);
			}
	};

	class Binary_Reader: public Reader {
		private:
			std::streampos end;
		public:
			bool has_next(){
				return end > file.tellg() ? true : false;
			}

			ms_timestamps read_from_file(){
				file.read(reinterpret_cast<char*>(&ts.pre), sizeof(uint64_t));
				file.read(reinterpret_cast<char*>(&ts.post), sizeof(uint64_t));

				return ts;
			}

			Binary_Reader(const char* fileName){
				file.open(fileName, std::ios::binary | std::ios::ate);
				check_stream(fileName);
				end = file.tellg();
				file.seekg(0, std::ios::beg);

				if ( (end - file.tellg()) % 16 != 0 ){
					std::cerr << "Invalid binary file detected. Are you sure it was created in ms_binary mode?" << "\n";
					exit(EXIT_FAILURE);
				}
			}
	};
				
		
	struct ms_stats {
		uint64_t average_latency = 0;
		uint32_t hits = 0;
		uint32_t misses = 0;
		uint32_t cold_misses = 0;
		uint32_t inval_ts = 0;
		uint32_t overwrites = 0;
		uint32_t cold_overwrites = 0;
	} stats;

	enum ms_mode { ms_text, ms_binary };

	std::ofstream file;
	
	uint64_t hit_list[UINT24_MAX + 1] = { 0 };
	std::mutex mtx[UINT24_MAX + 1];

	Writer* writer;
//	Text_Writer* ovr;

	bool has_hit = false;

	static void init(const char* fileName, ms_mode mode){
		if( mode == ms_binary ){
			writer = new Binary_Writer(fileName);
		} else {
			writer = new Text_Writer(fileName);
		}
//		ovr = new Text_Writer("overwrites.csv");
	}

	static void finish(){
		writer -> finish();
//		ovr -> finish();
	}

	static void add_entry(uint32_t identification, uint64_t timestamp){
		//uint64_t old_ts = hit_list[identification & INDEX_MASK];
		uint32_t index = identification & INDEX_MASK;
		while(!mtx[index].try_lock());
		hit_list[index] = timestamp;
		mtx[index].unlock();
		//std::cout << "timestamp: " << timestamp << " for identification: " << identification << "\n";
//		if( old_ts != 0 ){
//			++stats.overwrites;
//			if( !has_hit ){
//				++stats.cold_overwrites;
//			} else {
//				ovr -> write_to_file(identification, timestamp);
//			}
//		}
		//std::cout << "finished adding" << "\n";
	}

	static void test_for(uint32_t identification, uint64_t timestamp){
		uint32_t index = identification & INDEX_MASK;
		while(!mtx[index].try_lock());
		uint64_t old_ts = hit_list[index];
		hit_list[index] = 0;
		mtx[index].unlock();
		if( old_ts != 0 ){
			++stats.hits;
//			has_hit = true;
			writer -> write_to_file(old_ts, timestamp);
			//std::cout << "new: " << timestamp << "\n";
			//std::cout << "old: " << hit_list[identification].timestamp << "\n";
			////std::cout << "difference: " << (timestamp - hit_list[identification].timestamp)/1e6 << " ms\n";
		} else {
			++stats.misses;
//			if( !has_hit ){
//				++stats.cold_misses;
//			}
		}
	}

	static ms_stats post_process(const char* fileName, ms_mode mode){
		Reader* reader;
		if( mode == ms_binary ){
			reader = new Binary_Reader(fileName);
		} else {
			reader = new Text_Reader(fileName);
		}
		uint64_t size = 0, sum = 0;

		while( reader -> has_next() ){
			ms_timestamps ts = reader -> read_from_file();
			if( ts.pre < ts.post && ts.post - ts.pre < 1e9 ){
				sum += ts.post - ts.pre;
				++size;
			} else {
				++stats.inval_ts;
			}
		}
		std::cout << size << ", " << sum << "\n";
		stats.average_latency = size != 0 ? sum/size : 0;
		reader -> finish();
		return stats;
	}

	//----------------------Hashing-----------------------------//

	// this is not cryptographic hashing!
	std::hash<std::string> hasher;
	std::hash<uint64_t> uhash;

	static uint32_t hash(rte_mbuf* input){
		char* ptr = rte_pktmbuf_mtod(input, char*);

		return hasher(ptr);

//		char* ptr = (char*) malloc(100);
//		std::strncpy(ptr, input, 60);
//		ptr[99] = '\0';
//		return hasher(ptr);
	}

	static uint32_t get_identifier(rte_mbuf* buf){
		//std::cout << "Entered function \n";
		struct ether_hdr* eth = rte_pktmbuf_mtod(buf, struct ether_hdr*);
		if( rte_be_to_cpu_16(eth->ether_type) == 0x0800) {
			//std::cout << "Found an ipv4 packet\n";
			struct ipv4_hdr* ip = rte_pktmbuf_mtod_offset(buf, struct ipv4_hdr*, 14);

			// just for getting an identifier it is not neccessary to use the correct byteorder
			uint32_t packet_id = (uint32_t) ip->packet_id;
			//std::cout << "id: " << rte_be_to_cpu_16(ip->packet_id) << "\n";
			uint32_t hdr_checksum = (uint32_t) ip->hdr_checksum;
			//std::cout << "chksm: " << rte_be_to_cpu_16(ip->hdr_checksum) << "\n";

			uint64_t srcdst =(((uint64_t) ip->src_addr) << 32) + ip->dst_addr;
			uint32_t hash_val = uhash(srcdst);

			// hash of src and dst is added to hash of id (higher 16 bit) and checksum (lower 16 bit)
			return hash_val + uhash((packet_id << 16) + hdr_checksum);
		}
		std::cerr << "Identifiers for non ipv4 packets are currently not supported.\n";
		return 0;
	}
}

extern "C" {
	void ms_add_entry(uint32_t identification, uint64_t timestamp){
		moonsniff::add_entry(identification, timestamp);
	}

	void ms_test_for(uint32_t identification, uint64_t timestamp){
		moonsniff::test_for(identification, timestamp);
	}

	moonsniff::ms_stats ms_post_process(const char* fileName, moonsniff::ms_mode mode){
		return moonsniff::post_process(fileName, mode);
	}

	void ms_init(const char* fileName, moonsniff::ms_mode mode){ moonsniff::init(fileName, mode); }
	void ms_finish(){ moonsniff::finish(); }

	uint32_t ms_hash(rte_mbuf* input){
		return moonsniff::hash(input);
	}

	uint32_t ms_get_identifier(rte_mbuf* packet){
		return moonsniff::get_identifier(packet);
	}
}
