-- Reuse the crypto library bundled with KOReader on Kindle and desktop Linux.
local ffi = require("ffi")
require("ffi/loadlib")

ffi.cdef[[
typedef struct localsend_x509_st ls_x509;
typedef struct localsend_pkey_st ls_pkey;
typedef struct localsend_ec_key_st ls_ec_key;
typedef struct localsend_x509_name_st ls_name;
typedef struct localsend_asn1_time_st ls_time;
typedef struct localsend_asn1_integer_st ls_integer;
typedef struct localsend_md_st ls_md;
typedef struct localsend_md_ctx_st ls_md_ctx;
typedef struct localsend_bio_st ls_bio;
typedef struct localsend_bio_method_st ls_bio_method;
int RAND_bytes(unsigned char *, int);
ls_ec_key *EC_KEY_new_by_curve_name(int);
int EC_KEY_generate_key(ls_ec_key *);
void EC_KEY_free(ls_ec_key *);
ls_pkey *EVP_PKEY_new(void);
void EVP_PKEY_free(ls_pkey *);
int EVP_PKEY_set1_EC_KEY(ls_pkey *, ls_ec_key *);
const ls_md *EVP_sha256(void);
ls_md_ctx *EVP_MD_CTX_new(void);
void EVP_MD_CTX_free(ls_md_ctx *);
int EVP_DigestInit_ex(ls_md_ctx *, const ls_md *, void *);
int EVP_DigestUpdate(ls_md_ctx *, const void *, size_t);
int EVP_DigestFinal_ex(ls_md_ctx *, unsigned char *, unsigned int *);
ls_x509 *X509_new(void);
void X509_free(ls_x509 *);
int X509_set_version(ls_x509 *, long);
ls_integer *X509_get_serialNumber(ls_x509 *);
int ASN1_INTEGER_set(ls_integer *, long);
ls_time *X509_getm_notBefore(const ls_x509 *);
ls_time *X509_getm_notAfter(const ls_x509 *);
ls_time *X509_gmtime_adj(ls_time *, long);
int X509_set_pubkey(ls_x509 *, ls_pkey *);
ls_name *X509_get_subject_name(const ls_x509 *);
int X509_NAME_add_entry_by_txt(ls_name *, const char *, int, const unsigned char *, int, int, int);
int X509_set_issuer_name(ls_x509 *, const ls_name *);
int X509_sign(ls_x509 *, ls_pkey *, const ls_md *);
const ls_bio_method *BIO_s_mem(void);
ls_bio *BIO_new(const ls_bio_method *);
int BIO_free(ls_bio *);
int BIO_read(ls_bio *, void *, int);
int PEM_write_bio_X509(ls_bio *, ls_x509 *);
int PEM_write_bio_PrivateKey(ls_bio *, ls_pkey *, const void *, unsigned char *, int, void *, void *);
int chmod(const char *, unsigned int);
]]

local crypto = ffi.loadlib("crypto", "57", "crypto", "3", "crypto", "1.1", "crypto", nil)
local ssl = require("ssl")
local mime = require("mime")
local lfs = require("libs/libkoreader-lfs")
local Identity = {}

local function hex(binary)
    return (binary:gsub(".", function(byte) return ("%02X"):format(byte:byte()) end))
end

function Identity.randomId()
    local bytes = ffi.new("unsigned char[16]")
    assert(crypto.RAND_bytes(bytes, 16) == 1, "Cannot generate a LocalSend identifier")
    return hex(ffi.string(bytes, 16))
end

function Identity.sha256()
    local context = ffi.gc(assert(crypto.EVP_MD_CTX_new()), crypto.EVP_MD_CTX_free)
    assert(context ~= nil and crypto.EVP_DigestInit_ex(context, crypto.EVP_sha256(), nil) == 1)
    return function(chunk)
        if chunk then
            assert(crypto.EVP_DigestUpdate(context, chunk, #chunk) == 1)
        else
            local bytes = ffi.new("unsigned char[32]")
            assert(crypto.EVP_DigestFinal_ex(context, bytes, nil) == 1)
            return hex(ffi.string(bytes, 32))
        end
    end
end

function Identity.fingerprint(certificate)
    if not certificate then return end
    local encoded = certificate:pem():match("%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-(.-)%-%-%-%-%-END CERTIFICATE")
    if not encoded then return end
    local hash = Identity.sha256()
    hash(mime.unb64((encoded:gsub("%s", ""))))
    return hash()
end

local function writePem(path, write)
    local bio = ffi.gc(assert(crypto.BIO_new(crypto.BIO_s_mem())), crypto.BIO_free)
    assert(bio ~= nil and write(bio) == 1, "Cannot encode LocalSend TLS identity")
    local buffer = ffi.new("char[8192]")
    local length = crypto.BIO_read(bio, buffer, 8192)
    assert(length > 0 and length < 8192)
    local file = assert(io.open(path, "wb"))
    -- chmod is advisory on FAT volumes, which use mount-wide permissions.
    ffi.C.chmod(path, 384)
    local written, write_error = file:write(ffi.string(buffer, length))
    local closed, close_error = file:close()
    assert(written, write_error)
    assert(closed, close_error)
end

local function generate(key_path, certificate_path)
    local ec_key = ffi.gc(assert(crypto.EC_KEY_new_by_curve_name(415)), crypto.EC_KEY_free) -- P-256
    local private_key = ffi.gc(assert(crypto.EVP_PKEY_new()), crypto.EVP_PKEY_free)
    local certificate = ffi.gc(assert(crypto.X509_new()), crypto.X509_free)
    assert(ec_key ~= nil and private_key ~= nil and certificate ~= nil)
    assert(crypto.EC_KEY_generate_key(ec_key) == 1)
    assert(crypto.EVP_PKEY_set1_EC_KEY(private_key, ec_key) == 1)
    assert(crypto.X509_set_version(certificate, 2) == 1)
    local serial = tonumber(Identity.randomId():sub(1, 7), 16) + 1
    assert(crypto.ASN1_INTEGER_set(crypto.X509_get_serialNumber(certificate), serial) == 1)
    assert(crypto.X509_gmtime_adj(crypto.X509_getm_notBefore(certificate), -86400) ~= nil)
    assert(crypto.X509_gmtime_adj(crypto.X509_getm_notAfter(certificate), 315360000) ~= nil)
    assert(crypto.X509_set_pubkey(certificate, private_key) == 1)
    local subject = crypto.X509_get_subject_name(certificate)
    assert(crypto.X509_NAME_add_entry_by_txt(subject, "CN", 4097, "KOReader LocalSend Lite", -1, -1, 0) == 1)
    assert(crypto.X509_set_issuer_name(certificate, subject) == 1)
    assert(crypto.X509_sign(certificate, private_key, crypto.EVP_sha256()) > 0)
    writePem(key_path, function(bio)
        return crypto.PEM_write_bio_PrivateKey(bio, private_key, nil, nil, 0, nil, nil)
    end)
    writePem(certificate_path, function(bio) return crypto.PEM_write_bio_X509(bio, certificate) end)
end

function Identity.open(settings_directory)
    local directory = settings_directory .. "/localsend-lite"
    if not lfs.attributes(directory, "mode") then
        assert(lfs.mkdir(directory))
        ffi.C.chmod(directory, 448)
    end
    local key_path = directory .. "/key.pem"
    local certificate_path = directory .. "/certificate.pem"
    local function loadContexts()
        local file = io.open(certificate_path, "rb")
        if not file then return end
        local pem = file:read(8192)
        file:close()
        local certificate = pem and ssl.loadcertificate(pem)
        local fingerprint = Identity.fingerprint(certificate)
        if not fingerprint then return end
        local config = {
            protocol = "any", options = { "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
            key = key_path, certificate = certificate_path, verify = "none",
        }
        config.mode = "server"
        config.verify = { "peer" }
        config.verifyext = { "lsec_continue" }
        local server = ssl.newcontext(config)
        config.mode = "client"
        config.verify = "none"
        config.verifyext = nil
        local client = ssl.newcontext(config)
        if server and client then
            return { fingerprint = fingerprint, server = server, client = client }
        end
    end
    local identity = loadContexts()
    if identity then return identity end
    generate(key_path, certificate_path)
    return assert(loadContexts(), "Cannot load LocalSend TLS identity")
end

return Identity
