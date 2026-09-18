import { Chrome } from "@/components/Chrome";
import { TipForm } from "@/components/TipForm";

export default async function CreatorTipPage({
  params,
}: {
  params: Promise<{ handle: string }>;
}) {
  const { handle } = await params;
  return (
    <Chrome>
      <TipForm handle={decodeURIComponent(handle)} />
    </Chrome>
  );
}
