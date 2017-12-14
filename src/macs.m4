m4_dnl vim: ft=m4
m4_define(`SHELLQUOTE',
	`"m4_patsubst(`m4_patsubst(`$1', `"', `\\x22')', `#', `\\x23')"')m4_dnl
m4_define(`BASE64', 
	`m4_esyscmd(echo SHELLQUOTE(`$1') | openssl enc -base64 | xargs echo -n)')m4_dnl