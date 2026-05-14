import maxmind, { type CityResponse, type CountryResponse, type Reader } from 'maxmind';

let lookup: Reader<CityResponse> | null = null;
let attempted = false;

async function getLookup(): Promise<Reader<CityResponse> | null> {
	if (lookup) return lookup;
	if (attempted) return null;
	attempted = true;
	try {
		lookup = await maxmind.open<CityResponse>('maxmind/geolite2-city.mmdb');
		return lookup;
	} catch {
		return null;
	}
}

async function getLocation(ip?: string) {
	if (!ip || ip.trim() === '') return null;
	const reader = await getLookup();
	if (!reader) return null;
	const data = reader.get(ip);
	if (data === null) return null;
	const city = (data as CityResponse).city?.names.en;
	const region = (data as CityResponse).subdivisions?.map((subdiv) => subdiv.names.en).join(' / ');
	const country = (data as CountryResponse).country?.names.en;
	return { city, country, region };
}

export { getLocation };
