import { Chrome } from "@/components/Chrome";
import { CreatorDashboard } from "@/components/CreatorDashboard";

export default async function DashboardPage({
  params,
}: {
  params: Promise<{ handle: string }>;
}) {
  const { handle } = await params;
  return (
    <Chrome>
      <CreatorDashboard handle={decodeURIComponent(handle)} />
    </Chrome>
  );
}
