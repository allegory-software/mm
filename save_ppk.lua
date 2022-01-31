

strbuf *p	pk_save_sb(ssh2_userkey *key, const char *passphrase)
{
    strbuf *pub_blob, *priv_blob;
    unsigned char *priv_blob_encrypted;
    int priv_encrypted_len;
    int i;
    const char *cipherstr;
    unsigned char priv_mac[20];

    pub_blob = strbuf_new();
    ssh_key_public_blob(key->key, BinarySink_UPCAST(pub_blob));
    priv_blob = strbuf_new_nm();
    ssh_key_private_blob(key->key, BinarySink_UPCAST(priv_blob));

	 priv_encrypted_len = priv_blob->len;
    priv_encrypted_len -= priv_encrypted_len;
    priv_blob_encrypted = snewn(priv_encrypted_len, unsigned char);
    memset(priv_blob_encrypted, 0, priv_encrypted_len);
    memcpy(priv_blob_encrypted, priv_blob->u, priv_blob->len);

	 /* Create padding based on the SHA hash of the unpadded blob. This prevents
     * too easy a known-plaintext attack on the last block. */
    hash_simple(&ssh_sha1, ptrlen_from_strbuf(priv_blob), priv_mac);
    assert(priv_encrypted_len - priv_blob->len < 20);
    memcpy(priv_blob_encrypted + priv_blob->len, priv_mac,
           priv_encrypted_len - priv_blob->len);

    /* Now create the MAC. */
    {
        strbuf *macdata;
        unsigned char mackey[20];
        char header[] = "putty-private-key-file-mac-key";

        macdata = strbuf_new_nm();
        put_stringz(macdata, ssh_key_ssh_id(key->key));
        put_stringz(macdata, "none");
        put_stringz(macdata, "");
        put_string(macdata, pub_blob->s, pub_blob->len);
        put_string(macdata, priv_blob_encrypted, priv_encrypted_len);

        ssh_hash *h = ssh_hash_new(&ssh_sha1);
        put_data(h, header, sizeof(header)-1);
        ssh_hash_final(h, mackey);
        mac_simple(&ssh_hmac_sha1, make_ptrlen(mackey, 20),
                   ptrlen_from_strbuf(macdata), priv_mac);
        strbuf_free(macdata);
        smemclr(mackey, sizeof(mackey));
    }

    strbuf *out = strbuf_new_nm();
    strbuf_catf(out, "PuTTY-User-Key-File-2: %s\n", ssh_key_ssh_id(key->key));
    strbuf_catf(out, "Encryption: %s\n", "none");
    strbuf_catf(out, "Comment: %s\n", "");
    strbuf_catf(out, "Public-Lines: %d\n", base64_lines(pub_blob->len));
    base64_encode_s(BinarySink_UPCAST(out), pub_blob->u, pub_blob->len, 64);
    strbuf_catf(out, "Private-Lines: %d\n", base64_lines(priv_encrypted_len));
    base64_encode_s(BinarySink_UPCAST(out),
                    priv_blob_encrypted, priv_encrypted_len, 64);
    strbuf_catf(out, "Private-MAC: ");
    for (i = 0; i < 20; i++)
        strbuf_catf(out, "%02x", priv_mac[i]);
    strbuf_catf(out, "\n");

    strbuf_free(pub_blob);
    strbuf_free(priv_blob);
    smemclr(priv_blob_encrypted, priv_encrypted_len);
    sfree(priv_blob_encrypted);
    return out;
}

bool ppk_save_f(const Filename *filename, ssh2_userkey *key,
                const char *passphrase)
{
    FILE *fp = f_open(filename, "wb", true);
    if (!fp)
        return false;

    strbuf *buf = ppk_save_sb(key, passphrase);
    bool toret = fwrite(buf->s, 1, buf->len, fp) == buf->len;
    if (fclose(fp))
        toret = false;
    strbuf_free(buf);
    return toret;
}
