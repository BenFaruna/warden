export async function GET(req: Request) {
    if (!process.env.COUTRIES_API_KEY) {
        return Response.json({ error: "COUTRIES_API_KEY is not defined" }, { status: 500 })
    };

    const country = new URL(req.url).searchParams.get("country") ?? "Unknown";
    if (!country) {
        return Response.json({ error: "Country name is not provided" }, { status: 500 });
    }
    const response = await fetch(
        `https://api.restcountries.com/countries/v5/names.common/${encodeURIComponent(country)}`,
        {
            headers: {
                "Authorization": `Bearer ${process.env.COUTRIES_API_KEY}`
            }
        }
    );

    const { data } = await response.json();

    return data;  //.objects?.[0];
}
