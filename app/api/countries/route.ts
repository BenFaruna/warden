export async function GET(req: Request) {
    if (!process.env.COUNTRIES_API_KEY) {
        return Response.json({ error: "COUNTRIES_API_KEY is not defined" }, { status: 500 })
    };

    const country = new URL(req.url).searchParams.get("country") ?? "Unknown";
    if (!country) {
        return Response.json({ error: "Country name is not provided" }, { status: 400 });
    }
    try {
        const response = await fetch(
            `https://api.restcountries.com/countries/v5/names.common/${encodeURIComponent(country)}`,
            {
                headers: {
                    "Authorization": `Bearer ${process.env.COUNTRIES_API_KEY}`
                }
            }
        );

        if (response.status !== 200) {
            return Response.json({ error: "Failed to fetch country data" }, { status: response.status });
        }

        const { data } = await response.json();
        return Response.json(data.objects?.[0]);
    } catch (error) {
        return Response.json({ error: "Failed to fetch country data" }, { status: 500 });
    }
}
