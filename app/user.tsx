import { cookies } from 'next/headers'
 
export async function User() {
  const session = (await cookies()).get('__session')?.value
  return <pre>${JSON.stringify(session)}</pre>
}
