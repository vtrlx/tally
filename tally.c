/* tally.c — support library for Tally */

#include <lua.h>

#include <lualib.h>
#include <lauxlib.h>

static int
lua_get_is_devel(lua_State *L)
{
#ifdef DEVEL
	lua_pushboolean(L, 1);
#else
	lua_pushboolean(L, 0);
#endif
	return 1;
}

#ifndef DEVEL
const char *app_id = "ca.vlacroix.Tally";
#else
const char *app_id = "ca.vlacroix.Tally.Devel";
#endif

static int
lua_get_app_id(lua_State *L)
{
	lua_pushstring(L, app_id);
	return 1;
}

extern char _binary_tally_bytecode_start[];
extern char _binary_tally_bytecode_end[];

static const luaL_Reg tallylib[] = {
	{ "get_is_devel", lua_get_is_devel },
	{ "get_app_id", lua_get_app_id },
	{ NULL, NULL },
};

void
lua_prepare(lua_State *L, lua_CFunction f, const char *name)
/* Opens the given Lua library and inserts it into Lua's package.loaded table. This function is akin to calling require 'name' in Lua without capturing the result — simply preloading the package for a future require() where the result actually does get captured.
The main purpose of this is to avoid exporting a global variable from C code, to prevent awkward namespace collisions.
The first parameter is the Lua state to call into. The second is the luaopen_ function to call, and the third is the name under which the library should be stored. */
{
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loaded");
	lua_remove(L, -2);
	lua_pushstring(L, name);
	f(L);
	lua_settable(L, -3);
	lua_remove(L, -1);
}

int
main()
{
	lua_State *L;
	size_t tally_bytecode_len;
	int lua_result;

	L = luaL_newstate();
	lua_openlibs(L);
	lua_prepare(L, tallylib, "tallylib");

	tally_bytecode_len = ((size_t)_binary_tally_bytecode_end) - ((size_t)_binary_tally_bytecode_start);

	lua_result = luaL_loadbuffer(L, _binary_tally_bytecode_start, tally_bytecode_length, app_id);
	switch (lua_result) {
	case LUA_OK:
		lua_call(L, 0, 0);
		return 0;
	default:
		/* FIXME: Handle each error case individually. */
		fprintf(stderr, "An unrecoverable error occurred when loading Tally, preventing the program from starting.\n");
		return lua_result;
	}
}
