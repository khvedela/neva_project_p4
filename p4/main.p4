/* NEVA Project - VERSION FINALE PROPRE */
#include <core.p4>
#include <ebpf_model.p4>

/* On définit juste notre fonction externe pour la congestion.
   Le reste (ebpfFilter, etc.) est géré par l'include ci-dessus.
*/
extern void check_congestion(out bool drop);

/* --- HEADERS --- */
typedef bit<48> MacAddress_t;
typedef bit<32> IPv4Address_t;

header ethernet_t {
    MacAddress_t dstAddr;
    MacAddress_t srcAddr;
    bit<16>      etherType;
}

header ipv4_t {
    bit<4>        version;
    bit<4>        ihl;
    bit<8>        diffserv;
    bit<16>       totalLen;
    bit<16>       identification;
    bit<3>        flags;
    bit<13>       fragOffset;
    bit<8>        ttl;
    bit<8>        protocol;
    bit<16>       hdrChecksum;
    IPv4Address_t srcAddr;
    IPv4Address_t dstAddr;
}

struct Headers {
    ethernet_t ethernet;
    ipv4_t     ipv4;
}

/* --- PARSER --- */
parser MyParser(packet_in packet, out Headers headers) {
    state start {
        packet.extract(headers.ethernet);
        transition select(headers.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(headers.ipv4);
        transition accept;
    }
}

/* --- CONTROL --- */
control MyFilter(inout Headers headers, out bool pass) {
    apply {
        if (headers.ipv4.isValid()) {
            bool should_drop;
            
            /* Le compilateur va générer un appel C vers 'check_congestion'.
               C'est la méthode la plus robuste pour éviter les erreurs de Registres.
            */
            check_congestion(should_drop);

            if (should_drop) {
                pass = false; // DROP
            } else {
                pass = true;  // PASS
            }
        } 
        else {
            pass = true;
        }
    }
}

/* --- MAIN --- */
/* On utilise l'instanciation standard. */
ebpfFilter(MyParser(), MyFilter()) main;